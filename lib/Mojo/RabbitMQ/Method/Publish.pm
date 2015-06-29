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

  my $header_args = delete $args{header} || {};
  my $body        = delete $args{body}   || '';

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
        %$args,
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
