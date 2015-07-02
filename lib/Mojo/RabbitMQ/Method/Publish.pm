package Mojo::RabbitMQ::Method::Publish;
use Mojo::Base 'Mojo::RabbitMQ::Method';

sub setup {
  my $self = shift;

  $self->arguments({@_});

  return $self;
}

sub deliver {
  my $self = shift;

  return $self if !$self->channel->is_active;

  my %args = %{$self->arguments};

  my $header_args
    = {header => delete $args{header} || {}, weight => delete $args{weight}};
  my $body = delete $args{body} || '';

  $self->_publish(%args)->_header($header_args, $body)->_body($body)
    ->is_sent(1);

  $self->emit('success');

  return $self if !$args{mandatory} && !$args{immediate};

  $self->channel->return_cbs->{($args{exchange} || '') . '_'
      . $args{routing_key}} = $self;

  return $self;
}

sub _publish {
  my $self = shift;
  my %args = @_;

  $self->client->_write_frame(
    Net::AMQP::Protocol::Basic::Publish->new(
      exchange  => '',
      mandatory => 0,
      immediate => 0,
      %args,    # routing_key
      ticket => 0,
    ),
    $self->channel->id
  );

  return $self;
}

sub _header {
  my ($self, $args, $body,) = @_;

  $self->client->_write_frame(
    Net::AMQP::Frame::Header->new(
      weight => $args->{weight} || 0,
      body_size    => length($body),
      header_frame => Net::AMQP::Protocol::Basic::ContentHeader->new(
        content_type     => 'application/octet-stream',
        content_encoding => undef,
        headers          => {},
        delivery_mode    => 1,
        priority         => 1,
        correlation_id   => undef,
        expiration       => undef,
        message_id       => undef,
        timestamp        => time,
        type             => undef,
        user_id          => $self->client->login_user,
        app_id           => undef,
        cluster_id       => undef,
        %{ $args->{header} },
      ),
    ),
    $self->channel->id
  );

  return $self;
}

sub _body {
  my ($self, $body,) = @_;

  $self->client->_write_frame(Net::AMQP::Frame::Body->new(payload => $body),
    $self->channel->id);

  return $self;
}

1;

=encoding utf8

=head1 NAME

Mojo::RabbitMQ::Method::Publish - single class to do all of AMQP Publish method magic

=head1 SYNOPSIS

  use Mojo::RabbitMQ::Method::Publish;
  
  my $method = Mojo::RabbitMQ::Method::Publish->new(
    client => $client,
    channel => $channel
  )->setup(
    exchange    => 'mojo',
    routing_key => '',
    header      => {}
    body        => 'mojo',
    mandatory   => 0,
    immediate   => 0,
  )->deliver();
  
=head1 DESCRIPTION

=head1 EVENTS

L<Mojo::RabbitMQ::Method::Publish> inherits all events from L<Mojo::RabbitMQ::Method>.

=head1 ATTRIBUTES

L<Mojo::RabbitMQ::Method::Publish> inherits all attributes from L<Mojo::RabbitMQ::Method>.

=head1 METHODS

L<Mojo::RabbitMQ::Method::Publish> inherits all methods from L<Mojo::RabbitMQ::Method> with
following changes.

=head2 setup

  $method = $method->setup($arguments);

Only accepts common arguments for message publish chain. Which is:

=over 2

=item Frame::Method

=over 2

=item Basic::Publish

=over 2

=item * exchange

=item * routing_key

=item * mandatory

=item * immediate

=back

=back

=item Frame::Header

=over 2

=item Basic::ContentHeader

=over 2

=item * header

=item * weight

=back

=back

=item Frame::Body

=over 2

=item * body (as payload)

=back

=back

=head1 SEE ALSO

L<Mojo::RabbitMQ::Method>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2015, Sebastian Podjasek

Based on L<AnyEvent::RabbitMQ> - Copyright (C) 2010 Masahito Ikuta, maintained by C<< bobtfish@bobtfish.net >>

This program is free software, you can redistribute it and/or modify it under the terms of the Artistic License version 2.0.

=cut
