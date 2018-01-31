package Mojo::RabbitMQ::Client::Consumer;
use Mojo::Base 'Mojo::EventEmitter';
use Mojo::Promise;
require Mojo::RabbitMQ::Client;

use constant DEBUG => $ENV{MOJO_RABBITMQ_DEBUG} // 0;

has url      => undef;
has client   => undef;
has channel  => undef;
has queue    => undef;
has setup    => 0;
has defaults => sub { {} };

sub consume_p {
  my $self = shift;

  my $promise = Mojo::Promise->new()->resolve();

  unless ($self->client) {
    $promise = $promise->then(
      sub {
        warn "-- spawn new client\n" if DEBUG;
        my $client_promise = Mojo::Promise->new();
        my $client         = Mojo::RabbitMQ::Client->new(url => $self->url);
        $self->client($client);

        # Catch all client related errors
        $self->client->catch(sub { $client_promise->reject(@_) });

        # When connection is in Open state, open new channel
        $client->on(
          open => sub {
            warn "-- client open\n" if DEBUG;
            $client_promise->resolve(@_);
          }
        );
        $client->on('close' => sub { shift; $self->emit('close', @_) });

        # Start connection
        $client->connect;

        return $client_promise;
      }
    );
  }

  # Create a new channel with auto-assigned id
   unless ($self->channel)  {
    $promise = $promise->then(
      sub {
        warn "-- create new channel\n" if DEBUG;
        my $channel_promise = Mojo::Promise->new;
        my $channel         = Mojo::RabbitMQ::Client::Channel->new();

        $channel->catch(sub { $channel_promise->reject(@_) });
        $channel->on(close => sub { warn 'Channel closed: ' . $_[1]->method_frame->reply_text; });

        $channel->on(
          open => sub {
            my ($channel) = @_;
            warn "-- channel opened\n" if DEBUG;

            $self->channel($channel);
            $channel->qos(%{$self->defaults->{qos}})->deliver;
            $channel_promise->resolve();
          }
        );

        $self->client->open_channel($channel);
        return $channel_promise;
      }
    );
  }

  # Start consuming messages
  $promise = $promise->then(
    sub {
      my $consumer_promise = Mojo::Promise->new;
      my $consumer = $self->channel->consume(
        queue => $self->client->url->query->param('queue'),
        %{$self->defaults->{consumer}}
      );
      $consumer->on(
        message => sub {
          warn "-- message received\n" if DEBUG;
          my ($client, $message) = @_;
          $self->emit('message', $message);
        }
      );
      $consumer->on('success' => sub { $consumer_promise->resolve(@_) });
      $consumer->deliver;
      return $consumer_promise;
    }
  );

  return $promise;
}

sub close {
  my $self = shift;

  if ($self->client) {
    $self->client->close();
  }
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
  $consumer->consume_p->wait;

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
