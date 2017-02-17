use Test::More tests => 12;

BEGIN { use_ok 'Mojo::RabbitMQ::Client' }

sub failure {
  my ($test, $details) = @_;
  fail($test);
  diag("Details: " . $details) if $details;
  Mojo::IOLoop->stop;
}

my $run_id        = time();
my $exchange_name = 'mrc_test_' . $run_id;
my $queue_name    = 'mrc_test_queue' . $run_id;

my $amqp
  = Mojo::RabbitMQ::Client->new(
  url => ($ENV{MOJO_RABBITMQ_URL} || 'rabbitmq://guest:guest@127.0.0.1:5672/')
  );

$amqp->ioloop->timer(    # Global test timeout
  10 => sub {
    failure('Test timeout');
  }
);

$amqp->catch(sub { failure('Connection or other server errors') });
$amqp->on(connect => sub { pass('Connected to server') });
$amqp->on(
  open => sub {
    my ($self) = @_;

    pass('Protocol opened');

    my $channel = Mojo::RabbitMQ::Client::Channel->new();
    $channel->on(
      open => sub {
        my ($channel) = @_;

        pass('Channel opened');

        my $exchange = $channel->declare_exchange(
          exchange    => $exchange_name,
          type        => 'topic',
          auto_delete => 1,
        );
        $exchange->catch(sub { failure('Failed to declare exchange') });
        $exchange->on(
          success => sub {
            pass('Exchange declared');

            my $queue = $channel->declare_queue(queue => $queue_name,
              auto_delete => 1,);
            $queue->catch(sub { failure('Failed to declare queue') });
            $queue->on(
              success => sub {
                pass('Queue declared');

                my $bind = $channel->bind_queue(
                  exchange    => $exchange_name,
                  queue       => $queue_name,
                  routing_key => $queue_name,
                );
                $bind->catch(sub { failure('Failed to bind queue') });
                $bind->on(
                  success => sub {
                    pass('Queue bound');

                    my $publish = $channel->publish(
                      exchange    => $exchange_name,
                      routing_key => $queue_name,
                      body        => 'Test message',
                      mandatory   => 0,
                      immediate   => 0,
                      header      => {}
                    );
                    $publish->catch(sub { failure('Message not published') });
                    $publish->on(
                      success => sub {
                        pass('Message published');
                      }
                    );
                    $publish->on(return => sub { failure('Message returned') }
                    );
                    $publish->deliver();

                    my $consumer = $channel->consume(queue => $queue_name,);
                    $consumer->on(
                      success => sub {
                        pass('Subscribed to queue');
                      }
                    );
                    $consumer->on(
                      message => sub {
                        pass('Got message');
                        $amqp->close;
                      }
                    );
                    $consumer->catch(sub { failure('Subscription failed') });
                    $consumer->deliver;
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
    $channel->on(close =>
        sub { failure('Channel closed', $_[1]->method_frame->reply_text) });
    $channel->catch(sub { failure('Channel error') });

    $self->open_channel($channel);
  }
);
$amqp->on(close => sub { pass('Connection closed') });
$amqp->on(disconnect => sub { pass('Disconnected'); Mojo::IOLoop->stop });
$amqp->connect();

Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
