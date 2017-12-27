use Test::More tests => 10;

BEGIN { use_ok 'Mojo::RabbitMQ::Client::Publisher' }

my $publisher = Mojo::RabbitMQ::Client::Publisher->new(
  url => 'amqp://guest:guest@127.0.0.1:5672/?exchange=mojo&routing_key=mojo'
);

$publisher->publish('plain text');

warn "== first message done\n";

$publisher->publish(['dupa'])->then(sub { warn "== message published\n" })->wait;
