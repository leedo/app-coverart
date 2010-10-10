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
      my $search = $self->discogs_uri("search", type => "releases", q => $query);

      http_get $search, headers => {"Accept-Encoding" => "gzip"}, sub {
        my ($body, $headers) = @_;
        gunzip \$body => \(my $xml);

        my $xs = XMLin($xml, ForceArray => ['result']);

        if ($xs->{stat} eq 'ok' && $xs->{searchresults}{numResults} > 0) {
          my  $releases = [ map {[$_->{title}, $_->{uri}]} @{ $xs->{searchresults}{result}} ];
          $self->cache->set("query-$query", $releases, 60 * 60 * 24);
          if (@$releases) {
            # get images for each release
            $self->get_release_data($releases, $respond);
            return;
          }
        }
        # fall back to empty response
        $respond->($empty);
      };
    }
  }
}

sub get_release_data {
  my ($self, $releases, $respond) = @_;

  my $images = [];
  my $count = scalar @$releases;
  my @downloads;
  my $timer;

  if (!@$releases) {
    $respond->([200, ["Content-Type", "text/json"], ["[]"]]);
  }

  my $next = sub {
    my $more = shift;
    push @$images, @$more if $more;
    $count--;
    if ($count <= 0) {
      undef $timer; # cancel timer
      $respond->([200, ["Content-Type", "text/json"], [to_json $images, {utf8 => 1}]]);
    }
  };

  # after 10 seconds just send what we have
  $timer = AnyEvent->timer(after => 10, cb => sub {
    print STDERR "Canceled image downloads early...\n";
    $count = 0;
    @downloads = (); # cancel any downloads
    $next->();
  });
 
  for my $release (@$releases) {
    my ($title, $uri) = @$release;
    my ($id) = ($uri =~ /(\d+)$/);
    my $release = $self->discogs_uri("release/$id");

    if (my $more = $self->cache->get("release-$id")) {
      $next->($more); 
      next;
    }
          
    my $download = http_get $release, headers => {"Accept-Encoding" => "gzip"}, sub {
      my ($body, $headers) = @_;
      gunzip \$body => \(my $xml);

      my $xs = XMLin($xml, ForceArray => ['image']);
      my $more = [];
      if ($xs->{stat} eq 'ok' && $xs->{release} > 0) {
        $more = $xs->{release}{images}{image};
        if ($xs->{release}{released} =~ /^(\d{4})/) {
          $title .= " ($1)";
        }
        $more = [ map {$_->{title} = $title; $_} @$more ];
        $self->cache->set("release-$id", $more, 60 * 60 * 24 * 30);
      }
      $next->($more);
    };
    push @downloads, $download;
  }
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
