use Plack::Builder;
use lib 'lib';
use App::Coverart;

my $app = App::Coverart->new(api_key => "5b4bea98ec")->to_psgi;
