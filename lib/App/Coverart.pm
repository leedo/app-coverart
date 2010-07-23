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
  default => sub {
    CHI->new(
      driver => "File",
      root_dir => "./var/cache",
    );
  }
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
  
  if ($req->path_info eq "/") {
    return $self->search($req);
  }

  return [404, ["Content-Type", "text/plain"], ["not found"]];
}

sub search {
  my ($self, $req) = @_;

  return sub {
    my $respond = shift;

    my $query = $req->param("query");

    if (my $uris = $self->cache->get("query-$query")) {
      $self->get_release_data($uris, $respond);
    }
    else {
      my $search = $self->discogs_uri("search", type => "releases", q => $query);

      http_get $search, headers => {"Accept-Encoding" => "gzip"}, sub {
        my ($body, $headers) = @_;
        gunzip \$body => \(my $xml);

        my $uris = [];
        my $xs = XMLin($xml, ForceArray => ['result']);

        if ($xs->{stat} eq 'ok' && $xs->{searchresults}{numResults} > 0) {
          $uris = [ map {$_->{uri}} @{ $xs->{searchresults}{result}} ];
          $self->cache->set("query-$query", $uris, 60 * 60 * 24);
        }
        $self->get_release_data($uris, $respond);
      };
    }
  }
}

sub get_release_data {
  my ($self, $uris, $respond) = @_;

  my $images = [];
  my $count = scalar @$uris;

  if (!@$uris) {
    $respond->([200, ["Content-Type", "text/plain"], [to_json []]]);
  }

  my $next = sub {
    my $more = shift;
    push @$images, @$more;
    $count--;
    if (!$count) {
      $respond->([200, ["Content-Type", "text/plain"], [to_json $images]]);
    }
  };

  for my $uri (@$uris) {
    my ($id) = ($uri =~ /(\d+)$/);
    my $release = $self->discogs_uri("release/$id");

    if (my $more = $self->cache->get("release-$id")) {
      $next->($more); 
    }
          
    http_get $release, headers => {"Accept-Encoding" => "gzip"}, sub {
      my ($body, $headers) = @_;
      gunzip \$body => \(my $xml);

      my $xs = XMLin($xml, ForceArray => ['image']);
      if ($xs->{stat} eq 'ok' && $xs->{release} > 0) {
        my $more = [ map {$_->{uri}} @{ $xs->{release}{images}{image} } ];
        $self->cache->set("release-$id", $more, 60 * 60 * 24 * 30);
        $next->($more);
      }
    };
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
