use Test::More tests => 5;

BEGIN {
  use_ok 'Mojo::RabbitMQ::Client';
  use_ok 'Mojo::RabbitMQ::Client::Publisher';
}

my $run_id        = time();
my $exchange_name = 'mrc_test_' . $run_id;
my $queue_name    = 'mrc_test_queue' . $run_id;

my $url
  = $ENV{MOJO_RABBITMQ_URL}
  || 'amqp://guest:guest@127.0.0.1:5672/?exchange='
  . $exchange_name
  . '&routing_key='
  . $queue_name;

# setup
my $client = Mojo::RabbitMQ::Client->new(url => $url);
$client->connect_p->then(
  sub {
    my $client = shift;
    return $client->acquire_channel_p();
  }
)->then(
  sub {
    warn "**** then->connected";
    my $channel = shift;

    return $channel->declare_exchange_p(
      exchange    => $exchange_name,
      type        => 'topic',
      auto_delete => 1
    );
  }
)->then(
  sub {
    warn "**** then->declare_exchange_p";
    my $channel = shift;

    return $channel->declare_queue_p(queue => $queue_name, auto_delete => 1);
  }
)->then(
  sub {
    warn "**** then->declare_queue_p";
    my $channel = shift;

    return $channel->bind_queue_p(
      exchange    => $exchange_name,
      queue       => $queue_name,
      routing_key => $queue_name,
    );
  }
)->then(
  sub {
    warn "!!!! setup done\n";
  }
)->wait;


# tests

my $publisher = Mojo::RabbitMQ::Client::Publisher->new(url => $url);

$publisher->publish('plain text')->then(sub { pass('text published') })->wait;

$publisher->publish({json => 'object'})->then(sub { pass('json published') })
  ->wait;

$publisher->publish(['array'])->then(sub { pass('array published') })->wait;

$publisher->publish(
  {json         => 'object'},
  {content_type => 'text/plain'},
  routing_key => '#'
)->then(sub { pass('json published') })->wait;


# verify

my $consumer = Mojo::RabbitMQ::Client->consumer(
  url      => $url . "&queue_name=" . $queue_name,
  defaults => {
    qos      => {prefetch_count => 1},
    queue    => {auto_delete    => 1},
    consumer => {no_ack         => 0},
  }
);

$consumer->catch(sub { failure('Consumer: Connection or other server errors') }
);
$consumer->on(connect => sub { pass('Consumer: Connected to server') });
$consumer->on(
  'message' => sub {
    my ($consumer, $message) = @_;
    pass('Consumer: Got message - ' . $message);
    $consumer->close();
  }
);
$consumer->on(
  close => sub { pass('Consumer: Disconnected'); Mojo::IOLoop->stop });
$consumer->start();
