use Mojolicious::Lite;
use Mojo::EventEmitter;
use Mojo::RabbitMQ::Client;

helper events => sub { state $events = Mojo::EventEmitter->new };

get '/' => 'chat';

websocket '/channel' => sub {
  my $c = shift;

  $c->inactivity_timeout(3600);

  # Forward messages from the browser
  $c->on(message => sub { shift->events->emit(mojochat => ['browser', shift]) }
  );

  # Forward messages to the browser
  my $cb = $c->events->on(mojochat => sub { $c->send(join(': ', @{$_[1]})) });
  $c->on(finish => sub { shift->events->unsubscribe(mojochat => $cb) });
};

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

        # Forward every message from browser to message queue
        app->events->on(
          mojochat => sub {
            return unless $_[1]->[0] eq 'browser';

            $channel->publish(
              exchange    => 'mojo',
              routing_key => '',
              body        => $_[1]->[1],
              mandatory   => 0,
              immediate   => 0,
              header      => {}
            )->deliver();
          }
        );

        # Create anonymous queue and bind it to fanout exchange named mojo
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

                # Forward every received messsage to browser
                $consumer->on(
                  message => sub {
                    app->events->emit(
                      mojochat => ['amqp', $_[1]->{body}->payload]);
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


# Minimal single-process WebSocket chat application for browser testing
app->start;
__DATA__

@@ chat.html.ep
<form onsubmit="sendChat(this.children[0]); return false"><input></form>
<div id="log"></div>
<script>
  var ws  = new WebSocket('<%= url_for('channel')->to_abs %>');
  ws.onmessage = function (e) {
    document.getElementById('log').innerHTML += '<p>' + e.data + '</p>';
  };
  function sendChat(input) { ws.send(input.value); input.value = '' }
</script>
