package Mojo::RabbitMQ::Client::Consumer;
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
  $client->catch(sub { die "Some error caught in client" });

  # When connection is in Open state, open new channel
  $client->on(
    open => sub {
      my $client        = shift;
      my $query         = $client->url->query;
      my $exchange_name = $query->param('exchange');
      my $queue_name    = $query->param('queue');

      # Create a new channel with auto-assigned id
      my $channel = Mojo::RabbitMQ::Client::Channel->new();

      $channel->catch(sub { die "Error on channel received" });

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
      $channel->on(close => sub { warn 'Channel closed' });

      $client->open_channel($channel);
    }
  );

  # Start connection
  $client->connect;
}

1;

=encoding utf8

=head1 NAME

Mojo::RabbitMQ::Client::Consumer - simple Mojo::RabbitMQ::Client based consumer

=head1 SYNOPSIS

  use Mojo::RabbitMQ::Client::Consumer;
  my $consumer = Mojo::RabbitMQ::Consumer->new(
    url      => 'amqp://guest:guest@127.0.0.1:5672/?exchange=mojo&queue=mojo',
    defaults => {
      qos      => {prefetch_count => 1},
      queue    => {durable        => 1},
      consumer => {no_ack         => 0},
    }
  );

  $consumer->catch(sub { die "Some error caught in Consumer" } );
  $consumer->on('success' => sub { say "Consumer ready" });
  $consumer->on(
    'message' => sub {
      my ($consumer, $message) = @_;

      $consumer->channel->ack($message)->deliver;
    }
  );

Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

=head1 DESCRIPTION

=head1 EVENTS

L<Mojo::RabbitMQ::Client::Consumer> inherits all events from L<Mojo::EventEmitter> and can emit the
following new ones.

=head1 ATTRIBUTES

L<Mojo::RabbitMQ::Client::Consumer> has following attributes.

=head1 METHODS

L<Mojo::RabbitMQ::Client::Consumer> inherits all methods from L<Mojo::EventEmitter> and implements
the following new ones.

=head1 SEE ALSO

L<Mojo::RabbitMQ::Client>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2015-2017, Sebastian Podjasek and others

This program is free software, you can redistribute it and/or modify it under the terms of the Artistic License version 2.0.

=cut
