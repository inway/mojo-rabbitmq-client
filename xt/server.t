use Test::More tests => 12;
use Test::Exception;

BEGIN { use_ok 'Mojo::RabbitMQ::Client' }

my $amqp
  = Mojo::RabbitMQ::Client->new(
  url => ($ENV{MOJO_RABBITMQ_URL} || 'rabbitmq://guest:guest@127.0.0.1:5672/')
  );

$amqp->timer(    # Global test timeout
  10 => sub {
    $amqp->stop;
  }
);

$amqp->catch(sub { fail('Connection or other server errors'); $amqp->stop; });
$amqp->on(connect => sub { pass('Connected to server') });
$amqp->on(
  open => sub {
    my ($self) = @_;

    pass('Protocol opened');

    my $channel = Mojo::RabbitMQ::Channel->new();
    $channel->on(
      open => sub {
        my ($channel) = @_;

        pass('Channel opened');

        my $exchange = $channel->declare_exchange(
          exchange    => 'test',
          type        => 'topic',
          auto_delete => 1,
        );
        $exchange->catch(
          sub {
            fail('Failed to declare exchange');
            $amqp->stop;
          }
        );
        $exchange->on(
          success => sub {
            pass('Exchange declared');

            my $queue = $channel->declare_queue(
              queue       => 'test_queue',
              auto_delete => 0,
              durable     => 1,
            );
            $queue->catch(
              sub {
                fail('Failed to declare queue');
                $amqp->stop;
              }
            );
            $queue->on(
              success => sub {
                pass('Queue declared');

                my $bind = $channel->bind_queue(
                  exchange    => 'test',
                  queue       => 'test_queue',
                  routing_key => 'test_queue',
                );
                $bind->catch(
                  sub {
                    fail('Failed to bind queue');
                    $amqp->stop;
                  }
                );
                $bind->on(
                  success => sub {
                    pass('Queue bound');

                    my $publish = $channel->publish(
                      exchange    => 'test',
                      routing_key => 'test_queue',
                      body        => 'Test message',
                      mandatory   => 0,
                      immediate   => 0,
                      header      => {}
                    );
                    $publish->catch(
                      sub {
                        fail('Message not published');
                        $amqp->stop;
                      }
                    );
                    $publish->on(
                      success => sub {
                        pass('Message published');
                      }
                    );
                    $publish->on(
                      return => sub {
                        fail('Message returned');
                        $amqp->stop;
                      }
                    );
                    $publish->deliver();

                    my $consumer = $channel->consume(queue => 'test_queue',);
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
                    $consumer->catch(
                      sub {
                        fail('Subscription failed');
                        $amqp->stop;
                      }
                    );
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
    $channel->on(close => sub { fail('Channel closed'); $amqp->stop; });
    $channel->catch(sub { fail('Channel not opened'); $amqp->stop; });

    $self->open_channel($channel);
  }
);
$amqp->on(close => sub { pass('Connection closed'); });
$amqp->on(disconnect => sub { pass('Disconnected'); $amqp->stop; });
$amqp->connect();

$amqp->start();
