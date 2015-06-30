use Mojo::RabbitMQ::Client;

$|++;

my $amqp
  = Mojo::RabbitMQ::Client->new(
  url => ($ENV{MOJO_RABBITMQ_URL} || 'rabbitmq://guest:guest@127.0.0.1:5672/')
  );
$amqp->on(
  open => sub {
    my ($self) = @_;

    my $channel = Mojo::RabbitMQ::Channel->new();
    $channel->on(
      open => sub {
        my $queue = $channel->declare_queue(exclusive => 1);
        $queue->on(
          success => sub {
            my $method = $_[1]->method_frame;
            my $bind   = $channel->bind_queue(
              exchange    => 'mojo',
              queue       => $method->queue,
              routing_key => '',
            );
            $bind->on(
              success => sub {
                my $consumer = $channel->consume(queue => $method->queue);
                $consumer->on(
                  message => sub {
                    print "<<< " . $_[1]->{body}->payload . " <<<\n";
                  }
                );
                $consumer->deliver();
              }
            );
            $bind->deliver();
          }
        );
        $queue->deliver();
      }
    );
    $self->open_channel($channel);
  }
);
$amqp->connect();

$amqp->start();
