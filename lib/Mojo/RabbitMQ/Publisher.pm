package Mojo::RabbitMQ::Publisher;
use Mojo::Base 'Mojo::EventEmitter';
use Mojo::RabbitMQ::Client;

has url      => undef;
has client   => undef;
has channel  => undef;
has setup    => 0;
has defaults => sub { {} };

sub publish {
  my $self = shift;
  my $body = shift;
  my $headers = shift;

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
      my $channel = Mojo::RabbitMQ::Channel->new();

      $channel->catch(sub { die "Error on channel received" });

      $channel->on(
        open => sub {
          my ($channel) = @_;
          $self->channel($channel);

          my %headers = (content_type => 'text/plain', %$headers);

          if (ref($body) eq 'HASH') {
            $headers{content_type} = 'application/json';
            $body = encode_json $task;
          }

          my $publish = $channel->publish(
            exchange    => $exchange_name,
            routing_key => $queue_name,
            mandatory   => 0,
            immediate   => 0,
            header      => \%headers,
            body        => $body
          );

          # Deliver this message to server
          $publish->on('success' => sub {
            $self->emit('success');
          });
          $publish->deliver();
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

Mojo::RabbitMQ::Publisher - simple Mojo::RabbitMQ::Client based publisher

=head1 SYNOPSIS

  use Mojo::RabbitMQ::Publisher;
  my $publisher = Mojo::RabbitMQ::Publisher->new(
    url => 'amqp://guest:guest@127.0.0.1:5672/?exchange=mojo&queue=mojo'
  );

  $publisher->catch(sub { die "Some error caught in Publisher" } );
  $publisher->on('success' => sub { say "Publisher ready" });

  $publisher->publish('plain text');
  $publisher->publish({encode => { to => 'json'}});

  Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

=head1 DESCRIPTION

=head1 EVENTS

L<Mojo::RabbitMQ::Publisher> inherits all events from L<Mojo::EventEmitter> and can emit the
following new ones.

=head1 ATTRIBUTES

L<Mojo::RabbitMQ::Publisher> has following attributes.

=head1 METHODS

L<Mojo::RabbitMQ::Publisher> inherits all methods from L<Mojo::EventEmitter> and implements
the following new ones.

=head1 SEE ALSO

L<Mojo::RabbitMQ::Client>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2015-2016, Sebastian Podjasek and others

This program is free software, you can redistribute it and/or modify it under the terms of the Artistic License version 2.0.

=cut
