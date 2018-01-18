use Test::More tests => 9;

BEGIN {
  use_ok 'Mojo::RabbitMQ::Client';
  use_ok 'Mojo::RabbitMQ::Client::Publisher';
}

SKIP: {
  skip "Not requested by user, set TEST_RMQ=1 environment variable to test", 7 unless $ENV{TEST_RMQ};

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
      shift->acquire_channel_p();
    }
  )->then(
    sub {
      shift->declare_exchange_p(
        exchange    => $exchange_name,
        type        => 'topic',
        auto_delete => 1
      );
    }
  )->then(
    sub {
      shift->declare_queue_p(queue => $queue_name, auto_delete => 1);
    }
  )->then(
    sub {
      shift->bind_queue_p(
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

  $publisher->publish_p('plain text')->then(sub { pass('text published') })->wait;

  $publisher->publish_p({json => 'object'})->then(sub { pass('json published') })
    ->wait;

  $publisher->publish_p(['array'])->then(sub { pass('array published') })->wait;

  $publisher->publish_p(
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
}
