use Test::More tests => 10;

BEGIN { use_ok 'Mojo::RabbitMQ::Client' }

sub failure {
  my ($test, $details) = @_;
  fail($test);
  diag("Details: " . $details) if $details;
  Mojo::IOLoop->stop;
}

sub handle_error {
  my $desc = $_[0] // 'Error';
  return sub {
    failure($desc, $_[1]->method_frame->reply_text);
  }
}

my $run_id        = time();
my $exchange_name = 'mrc_test_' . $run_id;
my $queue_name    = 'mrc_test_queue' . $run_id;

my $url = $ENV{MOJO_RABBITMQ_URL} || 'rabbitmq://guest:guest@127.0.0.1:5672/?exchange=' . $exchange_name . '&queue=' . $queue_name;

Mojo::IOLoop->timer(    # Global test timeout
  10 => sub {
    failure('Test timeout');
  }
);

my $client = Mojo::RabbitMQ::Client->new(url => $url);
$client->catch(handle_error('Connection or other server errors'));
$client->on(
  open => sub {
    pass('Client connected');

    my $channel = Mojo::RabbitMQ::Client::Channel->new();
    $channel->catch(handle_error("Channel error"));
    $channel->on(close => handle_error("Channel error"));
    $channel->on(
      open => sub {
        pass('Channel opened');

        my $exchange = $channel->declare_exchange(
          exchange    => $exchange_name,
          type        => 'topic',
          auto_delete => 1,
        );
        $exchange->catch(handle_error('Failed to declare exchange'));
        $exchange->on(
          success => sub {
            pass('Exchange declared');

            my $queue = $channel->declare_queue(queue => $queue_name,
              auto_delete => 1,);
            $queue->catch(handle_error('Failed to declare queue'));
            $queue->on(
              success => sub {
                pass('Queue declared');

                my $bind = $channel->bind_queue(
                  exchange    => $exchange_name,
                  queue       => $queue_name,
                  routing_key => $queue_name,
                );
                $bind->catch(handle_error('Failed to bind queue'));
                $bind->on(
                  success => sub {
                    pass('Queue bound');

                    my $publish = $channel->publish(
                      exchange    => $exchange_name,
                      routing_key => $queue_name,
                      body        => 'Test message'
                    );
                    $publish->on(success => sub {
                      pass('Message published');
                      start_consumer();
                      $client->close();
                    });
                    $publish->deliver();
                  }
                );
                $bind->deliver();
              }
            );
            $queue->deliver();
          }
        );
        $exchange->deliver();
      }
    );

    $client->open_channel($channel);
  }
);
$client->connect();

sub start_consumer {
  my $consumer = Mojo::RabbitMQ::Client->consumer(
    url      => $url,
    defaults => {
      qos      => {prefetch_count => 1},
      queue    => {auto_delete    => 1},
      consumer => {no_ack         => 0},
    }
  );

  $consumer->catch(sub { failure('Consumer: Connection or other server errors') });
  $consumer->on(connect => sub { pass('Consumer: Connected to server') });
  $consumer->on(
    'message' => sub {
      my ($consumer, $message) = @_;
      pass('Consumer: Got message');
      $consumer->close();
    }
  );
  $consumer->on(close => sub { pass('Consumer: Disconnected'); Mojo::IOLoop->stop });
  $consumer->start();
}

Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
