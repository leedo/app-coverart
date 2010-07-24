use Plack::Builder;
use lib 'lib';
use App::Coverart;
use Web::ImageProxy;

my $app = App::Coverart->new(api_key => "5b4bea98ec", cache_root => "./var/cache")->to_psgi;

builder {
  enable "Plack::Middleware::Static",
            path => qr{^/(js|css)/}, root => './htdocs/';
  mount "/api" => $app;
  mount "/" => Plack::App::File->new(file => "./htdocs/index.html");
  mount "/image" => Web::ImageProxy->new(cache_root => "./var/cache")->to_app;
  mount "/favicon.ico" => sub {[404, ["Content-Type", "text/plain"], ["not found"]]};
}
