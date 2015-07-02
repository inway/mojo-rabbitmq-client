package Mojo::RabbitMQ::Method;
use Mojo::Base 'Mojo::EventEmitter';

has is_sent   => 0;
has client    => undef;
has channel   => undef;
has name      => undef;
has arguments => sub { {} };
has expect    => undef;

sub setup {
  my $self = shift;
  $self->name(shift);
  $self->arguments(shift);
  $self->expect(shift);

  return $self;
}

sub deliver {
  my $self = shift;

  return 0 unless $self->channel->_assert_open();

  $self->client->_write_expect(
    $self->name   => $self->arguments,
    $self->expect => sub { $self->emit('success', @_); },
    sub { $self->emit('error', @_); }, $self->channel->id,
  );
  $self->is_sent(1);

  return 1;
}

1;

=encoding utf8

=head1 NAME

Mojo::RabbitMQ::Method - it's a generic class for all AMQP method calls

=head1 SYNOPSIS

  use Mojo::RabbitMQ::Method;
  
  my $method = Mojo::RabbitMQ::Method->new(
    client => $client,
    channel => $channel
  )->setup(
    'Basic::Consume' => {
      ...
    },
    ['Basic::ConsumeOk', ...]
  );
  
  # Watch for errors
  $method->on(error => sub { warn "Error in reception: " . $_[1] });
  
  # Send this frame to AMQP
  $method->deliver;

=head1 DESCRIPTION

L<Mojo::RabbitMQ::Method> is general class for every AMQP method call.

=head1 EVENTS

L<Mojo::RabbitMQ::Method> inherits all events from L<Mojo::EventEmitter> and can emit the
following new ones.

=head2 success

  $method->on(success => sub {
    my ($method, $frame) = @_;
    ...
  });

Emitted when one of expected replies is received.

=head2 message

Can be emmited by consumption & get methods.

=head2 empty

Can be emmited by get method, when no messages are available on queue.

=head1 ATTRIBUTES

L<Mojo::RabbitMQ::Method> has following attributes.

=head2 is_sent

  $method->is_sent ? "Method was sent" : "Method is still pending delivery";

=head2 client

  my $client = $method->client;
  $method->client($client);

=head2 name

  my $name = $method->name;
  $method->name('Basic::Get');

=head2 arguments

  my $arguments = $method->arguments;
  $method->arguments({no_ack => 1, ticket => 0, queue => 'amq.queue'});

=head2 expect

  my $expectations = $method->expect;
  $method->expect([qw(Basic::GetOk Basic::GetEmpty)]);

=head1 METHODS

L<Mojo::RabbitMQ::Method> inherits all methods from L<Mojo::EventEmitter> and implements
the following new ones.

=head2 setup

  $method = $method->setup($name, $arguments, $expectations);

Sets AMQP method name, its arguments and expected replies.

=head2 deliver

  my $status = $method->deliver();
  
  This delivers AMQP method call to server. Returns C<<false>> when channel is not open, C<<true>> otherwise.
  On successful delivery->reply cycle emits C<<success>> event.
  C<<error>> is emitted when none of expected replies are received.

=head1 SEE ALSO

L<Mojo::RabbitMQ::Channel>, L<Mojo::RabbitMQ::Client>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2015, Sebastian Podjasek

Based on L<AnyEvent::RabbitMQ> - Copyright (C) 2010 Masahito Ikuta, maintained by C<< bobtfish@bobtfish.net >>

This program is free software, you can redistribute it and/or modify it under the terms of the Artistic License version 2.0.

=cut
