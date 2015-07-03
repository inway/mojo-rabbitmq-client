package Mojo::RabbitMQ::Channel;
use Mojo::Base 'Mojo::EventEmitter';

use Mojo::RabbitMQ::LocalQueue;
use Mojo::RabbitMQ::Method;
use Mojo::RabbitMQ::Method::Publish;

has id            => 0;
has is_open       => 0;
has is_active     => 0;
has client        => undef;
has queue         => sub { Mojo::RabbitMQ::LocalQueue->new };
has content_queue => sub { Mojo::RabbitMQ::LocalQueue->new };
has consumer_cbs  => sub { {} };
has return_cbs    => sub { {} };

sub _open {
  my $self = shift;

  if ($self->is_open) {
    $self->emit(error => 'Channel has already been opened');
    return $self;
  }

  weaken $self;
  $self->client->_write_expect(
    'Channel::Open'   => {},
    'Channel::OpenOk' => sub {
      $self->is_open(1)->is_active(1)->emit('open');
    },
    sub {
      $self->emit(
        error => 'Invalid response received while trying to open channel: '
          . shift);
    },
    $self->id,
  );

  return $self;
}

sub _push_queue_or_consume {
  my $self = shift;
  my ($frame) = @_;

  weaken $self;
  if ($frame->isa('Net::AMQP::Frame::Method')) {
    my $method_frame = $frame->method_frame;

    if ($method_frame->isa('Net::AMQP::Protocol::Channel::Close')) {
      $self->client->_write_frame(Net::AMQP::Protocol::Channel::CloseOk->new(),
        $self->id);
      $self->is_open(0)->is_active(0);
      $self->client->delete_channel($self->id);
      $self->emit(close => $frame);

      return $self;
    }
    elsif ($method_frame->isa('Net::AMQP::Protocol::Basic::Deliver')) {
      my $cb = $self->consumer_cbs->{$method_frame->consumer_tag} || sub { };
      $self->_push_read_header_and_body(
        'deliver',
        $frame => sub {
          $cb->emit(message => @_);
        },
        sub {
          $self->emit(error => 'Consumer callback failure: ' . shift);
        }
      );
      return $self;
    }
    elsif ($method_frame->isa('Net::AMQP::Protocol::Basic::Return')) {
      my $cb
        = $self->return_cbs->{$method_frame->exchange . '_'
          . $method_frame->routing_key}
        || sub { };
      $self->_push_read_header_and_body(
        'return',
        $frame => sub {
          $cb->emit(return => @_);
        },
        sub {
          $self->emit(error => 'Return callback failure: ' . shift);
        }
      );
      return $self;
    }
    elsif ($method_frame->isa('Net::AMQP::Protocol::Channel::Flow')) {
      $self->is_active($method_frame->active);
      $self->client->_write_frame(
        Net::AMQP::Protocol::Channel::FlowOk->new(
          active => $method_frame->active
        ),
        $self->id
      );

      return $self;
    }

    $self->queue->push($frame);
  }
  else {
    $self->content_queue->push($frame);
  }

  return $self;
}

sub close {
  my $self = shift;
  my $connection = $self->client or return;

  return $self if !$self->is_open;

  return $self->_close() if 0 == scalar keys %{$self->consumer_cbs};

  for my $consumer_tag (keys %{$self->consumer_cbs}) {
    my $method = $self->cancel(consumer_tag => $consumer_tag);
    $method->on(
      success => sub {
        $self->_close();
      }
    );
    $method->catch(
      sub {
        $self->_close();
        $self->emit(error => 'Error canceling consumption: ' . shift, @_);
      }
    );
    $method->deliver();
  }

  return $self;
}

sub _close {
  my $self = shift;
  my %args = @_;

  return unless 0 == scalar keys %{$self->consumer_cbs};

  $self->client->_write_expect(
    'Channel::Close'   => {},
    'Channel::CloseOk' => sub {
      $self->is_open(0)->is_active(0);
      $self->client->delete_channel($self->id);
      $self->emit('close');
    },
    sub {
      $self->is_open(0)->is_active(0);
      $self->client->delete_channel($self->id);
      $self->emit(error => 'Failed closing channel: ' . shift);
    },
    $self->id,
  );

  return $self;
}

sub _assert_open {
  my $self = shift;

  return 0 unless $self->is_open and $self->is_active;

  return 1;
}

sub _prepare_method {
  my $self = shift;

  return Mojo::RabbitMQ::Method->new(client => $self->client, channel => $self)
    ->setup(@_);
}

sub declare_exchange {
  my $self = shift;

  return $self->_prepare_method(
    'Exchange::Declare' => {
      type        => 'direct',
      passive     => 0,
      durable     => 0,
      auto_delete => 0,
      internal    => 0,
      @_,    # exchange
      ticket => 0,
      nowait => 0,    # FIXME
    },
    'Exchange::DeclareOk'
  );
}

sub delete_exchange {
  my $self = shift;

  return $self->_prepare_method(
    'Exchange::Delete' => {
      if_unused => 0,
      @_,             # exchange
      ticket => 0,
      nowait => 0,    # FIXME
    },
    'Exchange::DeleteOk'
  );
}

sub declare_queue {
  my $self = shift;

  return $self->_prepare_method(
    'Queue::Declare' => {
      queue       => '',
      passive     => 0,
      durable     => 0,
      exclusive   => 0,
      auto_delete => 0,
      no_ack      => 1,
      @_,
      ticket => 0,
      nowait => 0,    # FIXME
    },
    'Queue::DeclareOk'
  );
}

sub bind_queue {
  my $self = shift;

  return $self->_prepare_method(
    'Queue::Bind' => {
      @_,             # queue, exchange, routing_key
      ticket => 0,
      nowait => 0,    # FIXME
    },
    'Queue::BindOk'
  );
}

sub unbind_queue {
  my $self = shift;

  return $self->_prepare_method(
    'Queue::Unbind' => {
      @_,             # queue, exchange, routing_key
      ticket => 0,
    },
    'Queue::UnbindOk'
  );
}

sub purge_queue {
  my $self = shift;

  return $self->_prepare_method(
    'Queue::Purge' => {
      @_,             # queue
      ticket => 0,
      nowait => 0,    # FIXME
    },
    'Queue::PurgeOk'
  );
}

sub delete_queue {
  my $self = shift;

  return $self->_prepare_method(
    'Queue::Delete' => {
      if_unused => 0,
      if_empty  => 0,
      @_,    # queue
      ticket => 0,
      nowait => 0,    # FIXME
    },
    'Queue::DeleteOk'
  );
}

sub publish {
  my $self = shift;

  return Mojo::RabbitMQ::Method::Publish->new(
    client  => $self->client,
    channel => $self
  )->setup(@_);
}

sub consume {
  my $self = shift;

  my $method = $self->_prepare_method(
    'Basic::Consume' => {
      consumer_tag => '',
      no_local     => 0,
      no_ack       => 1,
      exclusive    => 0,
      @_,
      ticket => 0,
      nowait => 0
    },
    'Basic::ConsumeOk'
  );
  $method->on(
    success => sub {
      my $this  = shift;
      my $frame = shift;
      my $tag   = $frame->method_frame->consumer_tag;

      $self->consumer_cbs->{$tag} = $this;
    }
  );

  return $method;
}

sub cancel {
  my $self = shift;

  my $method = $self->_prepare_method(
    'Basic::Cancel',
    {
      @_,    # consumer_tag
      nowait => 0,
    },
    'Basic::CancelOk'
  );
  $method->on(
    success => sub {
      my $this  = shift;
      my $frame = shift;
      delete $self->consumer_cbs->{$frame->method_frame->consumer_tag};
    }
  );
  return $method;
}

sub get {
  my $self = shift;

  my $method = $self->_prepare_method(
    'Basic::Get',
    {
      no_ack => 1,
      @_,    # queue
      ticket => 0,
    },
    [qw(Basic::GetOk Basic::GetEmpty)]
  );
  $method->on(
    success => sub {
      my $this  = shift;
      my $frame = shift;
      $this->emit(empty => $frame)
        if $frame->method_frame->isa('Net::AMQP::Protocol::Basic::GetEmpty');
      $self->_push_read_header_and_body(
        'ok', $frame,
        sub {
          $this->emit(message => @_);
        },
        sub {
          $this->emit(error => 'Failed to get messages from queue');
        }
      );
    }
  );

  return $method;
}

sub ack {
  my $self = shift;
  my %args = @_;

  return $self->_prepare_method(
    'Basic::Ack' => {
      delivery_tag => 0,
      multiple =>
        (defined $args{delivery_tag} && $args{delivery_tag} != 0 ? 0 : 1),
      %args,
    }
  );
}

sub qos {
  my $self = shift;

  return $self->_prepare_method('Basic::Qos',
    {prefetch_count => 1, @_, prefetch_size => 0, global => 0,},
    'Basic::QosOk');
}

sub recover {
  my $self = shift;

  return $self->_prepare_method('Basic::Recover' => {requeue => 1, @_,});
}

sub reject {
  my $self = shift;

  return $self->_prepare_method(
    'Basic::Reject' => {delivery_tag => 0, requeue => 0, @_,});
}

sub select_tx {
  my $self = shift;

  return $self->_prepare_method('Tx::Select', {}, 'Tx::SelectOk');
}

sub commit_tx {
  my $self = shift;

  return $self->_prepare_method('Tx::Commit', {}, 'Tx::CommitOk');
}

sub rollback_tx {
  my $self = shift;

  return $self->_prepare_method('Tx::Rollback', {}, 'Tx::RollbackOk');
}

sub _push_read_header_and_body {
  my $self = shift;
  my ($type, $frame, $cb, $failure_cb) = @_;
  my $response = {$type => $frame};
  my $body_size = 0;

  $self->content_queue->get(
    sub {
      my $frame = shift;

      return $failure_cb->('Received data is not header frame')
        if !$frame->isa('Net::AMQP::Frame::Header');

      my $header_frame = $frame->header_frame;
      return $failure_cb->('Header is not Protocol::Basic::ContentHeader'
          . 'Header was '
          . ref $header_frame)
        if !$header_frame->isa('Net::AMQP::Protocol::Basic::ContentHeader');

      $response->{header} = $header_frame;
      $body_size = $frame->body_size;
    }
  );

  my $body_payload = "";
  my $next_frame;
  $next_frame = sub {
    my $frame = shift;

    return $failure_cb->('Received data is not body frame')
      if !$frame->isa('Net::AMQP::Frame::Body');

    $body_payload .= $frame->payload;

    if (length($body_payload) < $body_size) {

      # More to come
      $self->content_queue->get($next_frame);
    }
    else {
      $frame->payload($body_payload);
      $response->{body} = $frame;
      $cb->($response);
    }
  };

  $self->content_queue->get($next_frame);

  return $self;
}

sub DESTROY {
  my $self = shift;
  $self->close() if defined $self;
  return;
}

1;

=encoding utf8

=head1 NAME

Mojo::RabbitMQ::Channel - handles all channel related methods

=head1 SYNOPSIS

  use Mojo::RabbitMQ::Channel;
  
  my $channel = Mojo::RabbitMQ::Channel->new();

  $channel->catch(sub { warn "Some channel error occured: " . $_[1] });

  $channel->on(
    open => sub {
      my ($channel) = @_;
      ...
    }
  );
  $channel->on(close => sub { warn "Channel closed" });
  
  $client->open_channel($channel);

=head1 DESCRIPTION

L<Mojo::RabbitMQ::Channel> allows to call all channel related methods.

=head1 EVENTS

L<Mojo::RabbitMQ::Channel> inherits all events from L<Mojo::EventEmitter> and can emit the
following new ones.

=head2 open

  $channel->on(open => sub {
    my ($channel) = @_;
    ...
  });

Emitted when channel receives Open-Ok.

=head2 close

  $channel->on(close=> sub {
    my ($channel, $frame) = @_;
    ...
  });

Emitted when channel gets closed, C<<$frame>> contains close reason.

=head1 ATTRIBUTES

L<Mojo::RabbitMQ::Channel> has following attributes.

=head2 id

  my $id = $channel->id;
  $channel->id(20810);

If not set, L<Mojo::RabbitMQ::Client> sets it to next free number when channel is opened.

=head2 is_open

  $channel->is_open ? "Channel is open" : "Channel is closed";

=head2 is_active

  $channel->is_active ? "Channel is active" : "Channel is not active";

This can be modified on reception of Channel-Flow.

=head2 client

  my $client = $channel->client;
  $channel->client($client);

=head1 METHODS

L<Mojo::RabbitMQ::Channel> inherits all methods from L<Mojo::EventEmitter> and implements
the following new ones.

=head2 close

  $channel->close;

Cancels all consumers and closes channel afterwards.

=head2 declare_exchange

  my $exchange = $channel->declare_exchange(
    exchange => 'mojo',
    type => 'fanout',
    durable => 1,
    ...
  )->deliver;

This method creates an exchange if it does not exists. If it exists it verifies
that it settings are correct, if not - channel is closed with appropriate message.
  
=over 2

=item exchange

Unique exchange name

=item type

Type is one of AMQP server implemented types, for example: fanout, direct, topic, headers.

=item passive

If set server will not create the exchange. This can be used to check exchange existence
without creating it.

=item durable

Mark exchange as durable, which means that it will remain active upon server restart.
Non-durable exchanges will be purged on server restart.

=item auto_delete

If set, the exchange will be deleted when no queue is using it.

=item internal

Internal exchanges may not be used directly by publishers, but can be bound to other exchanges.

=back

=head2 delete_exchange

  $channel->delete_exchange(exchange => 'mojo')->deliver;
  
Deletes an exchange. When an exchange is deleted all queue bindings on that exchange are cancelled.

=over 2

=item exchange

Exchange name.

=item if_unused

Deletes only if unused. If exchange still has queue bindings server will raise a channel exception.

=back

=head2 declare_queue

  my $queue = $channel->declare_queue(queue => 'mq', durable => 1)->deliver

=head2 bind_queue

  $channel->bind_queue(
    exchange => 'mojo',
    queue => 'mq',
    routing_key => ''
  )->deliver;

=head2 unbind_queue

  $channel->unbind_queue(
    exchange => 'mojo',
    queue => 'mq',
    routing_key => ''
  )->deliver;

=head2 purge_queue

  $channel->purge_queue(queue => 'mq')->deliver;

=head2 delete_queue

  $channel->delete_queue(queue => 'mq', if_empty => 1)->deliver;

=head2 publish

  $channel->publish(
    exchange    => 'mojo',
    routing_key => 'mq',
    body        => 'simple text body',
  )->deliver();

=head2 consume

  my $consumer = $channel->consume(queue => 'mq');
  $consumer->on(message => sub { ... });
  $consumer->deliver;

=head2 cancel

  $channel->cancel(consumer_tag => 'amq.ctag....')

Cancels a consumer. All delivered messages are left unaffected and also new messages can be consumed until Cancel-Ok is received.

=over 2

=item consumer_tag

This is consumer tag received upon successful reception of Consume-Ok.

=back

=head2 get

=head2 ack

=head2 qos

  $channel->qos(prefetch_count => 1)->deliver;
  
Sets specified Quality of Service to channel, or entire connection. Accepts following arguments:

=over 2

=item prefetch_size

Prefetch window size in octets.

=item prefetch_count

Prefetch window in complete messages.

=item global

If set all settings will be applied connection wide.

=back

=head2 recover

=head2 reject

=head2 select_tx

=head2 commit_tx

=head2 rollback_tx

=head1 SEE ALSO

L<Mojo::RabbitMQ::Client>, L<Mojo::RabbitMQ::Method>, L<Net::AMQP::Protocol::v0_8>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2015, Sebastian Podjasek

Based on L<AnyEvent::RabbitMQ> - Copyright (C) 2010 Masahito Ikuta, maintained by C<< bobtfish@bobtfish.net >>

This program is free software, you can redistribute it and/or modify it under the terms of the Artistic License version 2.0.

=cut
