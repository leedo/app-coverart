package App::Coverart;

use AnyEvent::HTTP;
use Plack::Request;
use Any::Moose;
use CHI;
use URI;
use URI::QueryParam;
use JSON;
use IO::Uncompress::Gunzip qw/gunzip $GunzipError/;
use XML::Simple;

has api_key => (
  is => "ro",
  required => 1,
);

has cache => (
  is => "ro",
  lazy => 1,
  default => sub {
    my $self = shift;
    CHI->new(
      driver => "File",
      root_dir => $self->cache_root,
      namespace => "discogs",
    );
  }
);

has cache_root => (
  is => "ro",
  default => "./var/cache"
);

sub to_psgi {
  my ($self) = @_;
  return sub {
    $self->call(@_);
  }
}

sub call {
  my ($self, $env) = @_;
  my $req = Plack::Request->new($env);
  return $self->search($req);
}

sub search {
  my ($self, $req) = @_;

  return sub {
    my $respond = shift;

    my $query = $req->param("query");
    my $empty = [200, ['Content-Type', 'text/json'], ["[]"]];

    if (!$query) {
      $respond->($empty);
      return;
    }

    if (my $releases = $self->cache->get("query-$query")) {
      $self->get_release_data($releases, $respond);
    }
    else {
      my $releases = [];
      my ($end, @searches, $idle_w, $error);
      my $open_searches = 0;
      my $page = 1;
      my $max_pages = 5;

      my $done = sub {
        undef $idle_w;
        @searches = ();
        if ($error) {
          $respond->([503, [], [$error]]);
        }
        elsif (@$releases) {
          $self->cache->set("query-$query", $releases, 60 * 60 * 24 * 30); # cache for 1 month
          $self->get_release_data($releases, $respond);
        } else {
          $respond->($empty);
        }
      };

      $idle_w = AE::idle sub {
        if ($end and !$open_searches) {
          $done->();
          return;
        }

        return if $page > $max_pages;

        $open_searches++;

        my $my_page = $page++;
        my $uri = $self->discogs_uri("search", type => "releases", q => $query, page => $my_page);

        push @searches, http_get $uri, headers => {"Accept-Encoding" => "gzip"}, sub {
          my ($body, $headers) = @_;

          $open_searches--;
          my @results;

          gunzip \$body => \(my $xml);
          my $xs = eval { XMLin($xml, ForceArray => ['result']); };

          if ($xs and $xs->{stat} eq 'ok' and $xs->{searchresults}{numResults} > 0) {
            @results = map {[$_->{title}, $_->{uri}]} @{ $xs->{searchresults}{result}};

            push @$releases, @results;
          }
          elsif ($xs and $xs->{error}) {
            $error = $xs->{error};
            warn $error;
            $done->();
            return;
          }

          $end = $my_page if (!@results or $my_page >= $max_pages);
        };
      };
    }
  }
}

sub get_release_data {
  my ($self, $releases, $respond) = @_;

  if (!@$releases) {
    $respond->([200, ["Content-Type", "text/json"], ["[]"]]);
  }

  my $images = [];
  my (@downloads, $timer, $idle_w);
  my $count = scalar @$releases;
  my $open_downloads = 0;

  my $done = sub {
    undef $timer; # cancel timer
    undef $idle_w; # cancel idle timer
    $respond->([200, ["Content-Type", "text/json"], [to_json $images, {utf8 => 1}]]);
  };

  my $next = sub {
    my $more = shift;
    push @$images, @$more;
    $open_downloads--;
    $count--;
  };

  # after 10 seconds just send what we have
  $timer = AnyEvent->timer(after => 10, cb => sub {
    @downloads = (); # cancel any downloads
    $done->();
  });

  $idle_w = AE::idle sub {
    $open_downloads++;

    if (!$count) {
      $done->();
      return;
    }

    my $release = shift @$releases;
    return unless $release;

    my ($title, $uri) = @$release;
    my ($id) = ($uri =~ /(\d+)$/);
    $uri = $self->discogs_uri("release/$id");

    if (my $more = $self->cache->get("release-$id")) {
      $next->($more);
      return;
    }

    push @downloads, http_get $uri, headers => {"Accept-Encoding" => "gzip"}, sub {
      my ($body, $headers) = @_;
      my $more = [];

      gunzip \$body => \(my $xml);
      my $xs = XMLin($xml, ForceArray => ['image']);

      if ($xs->{stat} eq 'ok' && $xs->{release} > 0) {
        $more = $xs->{release}{images}{image};
        if ($xs->{release}{released} and  $xs->{release}{released} =~ /^(\d{4})/) {
          $title .= " ($1)";
        }
        $more = [ map {$_->{title} = $title; $_} grep {$_->{type} eq "primary"} @$more ];
        $self->cache->set("release-$id", $more, 60 * 60 * 24 * 30);
      }

      $next->($more);
    };
  };
}

sub discogs_uri {
  my ($self, $type, %params) = @_;
  my $uri;

  $uri = URI->new("http://www.discogs.com/$type");

  $uri->query_param(api_key => $self->api_key);
  $uri->query_param(f => "xml");

  for (keys %params) {
    $uri->query_param($_ => $params{$_});
  }

  return $uri->canonical;
}

1;
