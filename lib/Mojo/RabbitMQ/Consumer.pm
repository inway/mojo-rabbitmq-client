package Mojo::RabbitMQ::Consumer;
use Mojo::Base 'Mojo::EventEmitter';
use Mojo::RabbitMQ::Client;

has url      => undef;
has client   => undef;
has channel  => undef;
has setup    => 0;
has defaults => sub { {} };

sub start {
  my $self = shift;

  my $client = Mojo::RabbitMQ::Client->new(url => $self->url);
  $self->client($client);

  # Catch all client related errors
  $client->catch(sub { warn "Some error caught in client"; $client->stop });

  # When connection is in Open state, open new channel
  $client->on(
    open => sub {
      my $client        = shift;
      my $query         = $client->url->query;
      my $exchange_name = $query->param('exchange');
      my $queue_name    = $query->param('queue');

      # Create a new channel with auto-assigned id
      my $channel = Mojo::RabbitMQ::Channel->new();

      $channel->catch(sub { warn "Error on channel received"; $client->stop });

      $channel->on(
        open => sub {
          my ($channel) = @_;
          $self->channel($channel);
          $channel->qos(%{$self->defaults->{qos}})->deliver;

          my $queue = $channel->declare_queue(
            queue => $queue_name,
            %{$self->defaults->{queue}}
          );
          $queue->on(
            success => sub {
              my $bind = $channel->bind_queue(
                exchange    => $exchange_name,
                queue       => $queue_name,
                routing_key => $queue_name,
              );
              $bind->on(
                success => sub {

                  # Start consuming messages from
                  my $consumer = $channel->consume(
                    queue => $queue_name,
                    %{$self->defaults->{consumer}}
                  );
                  $consumer->on(
                    message => sub {
                      my ($client, $message) = @_;

                      $self->emit('message', $message);
                    }
                  );
                  $consumer->on('success' => sub { $self->emit('success') });
                  $consumer->deliver;
                }
              );
              $bind->on(error => sub { die "Error in binding" });
              $bind->deliver;
            }
          );
          $queue->deliver;

        }
      );
      $channel->on(close => sub { say 'Channel closed' });

      $client->open_channel($channel);
    }
  );

  # Start connection
  $client->connect;
}

1;
