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
          $cb->emit(reject => @_);
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
          $this->emit(message => $frame, @_);
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

Verify exchange exists, create if needed.

This method creates an exchange if it does not already exist, and if the
exchange exists, verifies that it is of the correct and expected class.

Following arguments are accepted:

=over 2

=item exchange

Unique exchange name

=item type

Each exchange belongs to one of a set of exchange types implemented by the server. The
exchange types define the functionality of the exchange - i.e. how messages are routed
through it. It is not valid or meaningful to attempt to change the type of an existing
exchange.

=item passive

If set, the server will reply with Declare-Ok if the exchange already exists with the same
name, and raise an error if not. The client can use this to check whether an exchange
exists without modifying the server state. When set, all other method fields except name
and no-wait are ignored. A declare with both passive and no-wait has no effect. Arguments
are compared for semantic equivalence.

=item durable

If set when creating a new exchange, the exchange will be marked as durable. Durable exchanges
remain active when a server restarts. Non-durable exchanges (transient exchanges) are purged
if/when a server restarts.

=item auto_delete

If set, the exchange is deleted when all queues have finished using it.

=item internal

If set, the exchange may not be used directly by publishers, but only when bound to other exchanges.
Internal exchanges are used to construct wiring that is not visible to applications.

=back

=head2 delete_exchange

  $channel->delete_exchange(exchange => 'mojo')->deliver;

Delete an exchange.

This method deletes an exchange. When an exchange is deleted all queue bindings on the exchange
are cancelled.

Following arguments are accepted:

=over 2

=item exchange

Exchange name.

=item if_unused

If set, the server will only delete the exchange if it has no queue bindings. If the exchange has
queue bindings the server does not delete it but raises a channel exception instead.

=back

=head2 declare_queue

  my $queue = $channel->declare_queue(queue => 'mq', durable => 1)->deliver

Declare queue, create if needed.

This method creates or checks a queue. When creating a new queue the client can
specify various properties that control the durability of the queue and its contents,
and the level of sharing for the queue.

Following arguments are accepted:

=over 2

=item queue

The queue name MAY be empty, in which case the server MUST create a new queue with
a unique generated name and return this to the client in the Declare-Ok method.

=item passive

If set, the server will reply with Declare-Ok if the queue already exists with the same
name, and raise an error if not. The client can use this to check whether a queue exists
without modifying the server state. When set, all other method fields except name and
no-wait are ignored. A declare with both passive and no-wait has no effect.
Arguments are compared for semantic equivalence.

=item durable

If set when creating a new queue, the queue will be marked as durable. Durable queues
remain active when a server restarts. Non-durable queues (transient queues) are purged
if/when a server restarts. Note that durable queues do not necessarily hold persistent
messages, although it does not make sense to send persistent messages to a transient queue.

=item exclusive

Exclusive queues may only be accessed by the current connection, and are deleted when
that connection closes. Passive declaration of an exclusive queue by other connections are
not allowed.

=item auto_delete

If set, the queue is deleted when all consumers have finished using it. The last consumer
can be cancelled either explicitly or because its channel is closed. If there was no consumer
ever on the queue, it won't be deleted. Applications can explicitly delete auto-delete queues
using the Delete method as normal.

=back

=head2 bind_queue

  $channel->bind_queue(
    exchange => 'mojo',
    queue => 'mq',
    routing_key => ''
  )->deliver;

Bind queue to an exchange.

This method binds a queue to an exchange. Until a queue is bound it will
not receive any messages. In a classic messaging model, store-and-forward
queues are bound to a direct exchange and subscription queues are bound
to a topic exchange.

Following arguments are accepted:

=over 2

=item queue

Specifies the name of the queue to bind.

=item exchange

Name of the exchange to bind to.

=item routing_key

Specifies the routing key for the binding. The routing key is used for
routing messages depending on the exchange configuration. Not all exchanges
use a routing key - refer to the specific exchange documentation. If the
queue name is empty, the server uses the last queue declared on the channel.
If the routing key is also empty, the server uses this queue name for the
routing key as well. If the queue name is provided but the routing key is
empty, the server does the binding with that empty routing key. The meaning
of empty routing keys depends on the exchange implementation.

=back

=head2 unbind_queue

  $channel->unbind_queue(
    exchange => 'mojo',
    queue => 'mq',
    routing_key => ''
  )->deliver;

Unbind a queue from an exchange.

This method unbinds a queue from an exchange.

Following arguments are accepted:

=over 2

=item queue

Specifies the name of the queue to unbind.

=item exchange

The name of the exchange to unbind from.

=item routing_key

Specifies the routing key of the binding to unbind.

=back

=head2 purge_queue

  $channel->purge_queue(queue => 'mq')->deliver;

Purge a queue.

This method removes all messages from a queue which are not awaiting acknowledgment.

Following arguments are accepted:

=over 2

=item queue

Specifies the name of the queue to purge.

=back

=head2 delete_queue

  $channel->delete_queue(queue => 'mq', if_empty => 1)->deliver;

Delete a queue.

This method deletes a queue. When a queue is deleted any pending messages
are sent to a dead-letter queue if this is defined in the server configuration,
and all consumers on the queue are cancelled.

Following arguments are accepted:

=over 2

=item queue

Specifies the name of the queue to delete.

=item if_unused

If set, the server will only delete the queue if it has no consumers. If the queue
has consumers the server does does not delete it but raises a channel exception instead.

=item if_empty

If set, the server will only delete the queue if it has no messages.

=back

=head2 publish

  my $message = $channel->publish(
    exchange    => 'mojo',
    routing_key => 'mq',
    body        => 'simple text body',
  );
  $message->deliver();

Publish a message.

This method publishes a message to a specific exchange. The message will be
routed to queues as defined by the exchange configuration and distributed to
any active consumers when the transaction, if any, is committed.

Following arguments are accepted:

=over 2

=item exchange

Specifies the name of the exchange to publish to. The exchange name can be empty,
meaning the default exchange. If the exchange name is specified, and that exchange
does not exist, the server will raise a channel exception.

=item routing_key

Specifies the routing key for the message. The routing key is used for routing
messages depending on the exchange configuration.

=item mandatory

This flag tells the server how to react if the message cannot be routed to a queue.
If this flag is set, the server will return an unroutable message with a Return method.
If this flag is zero, the server silently drops the message.

All rejections are emitted as C<reject> event.

  $message->on(reject => sub {
    my $message = shift;
    my $frame = shift;
    my $method_frame = $frame->method_frame;

    my $reply_code = $method_frame->reply_code;
    my $reply_text = $method_frame->reply_text;
  });

=item immediate

This flag tells the server how to react if the message cannot be routed to a queue consumer
immediately. If this flag is set, the server will return an undeliverable message with a
Return method. If this flag is zero, the server will queue the message, but with no guarantee
that it will ever be consumed.

As said above, all rejections are emitted as C<reject> event.

  $message->on(reject => sub { ... });

=back

=head2 consume

  my $consumer = $channel->consume(queue => 'mq');
  $consumer->on(message => sub { ... });
  $consumer->deliver;

This method asks the server to start a "consumer", which is a transient request for messages from a
specific queue. Consumers last as long as the channel they were declared on, or until the client cancels
them.

Following arguments are accepted:

=over 2

=item queue

Specifies the name of the queue to consume from.

=item consumer_tag

Specifies the identifier for the consumer. The consumer tag is local to a channel, so two clients can use the
same consumer tags. If this field is empty the server will generate a unique tag.

  $consumer->on(success => sub {
    my $consumer = shift;
    my $frame = shift;

    my $consumer_tag = $frame->method_frame->consumer_tag;
  });

=item no_local (not implemented in RabbitMQ!)

If the no-local field is set the server will not send messages to the connection that published them.

See L<RabbitMQ Compatibility and Conformance|https://www.rabbitmq.com/specification.html>

=item no_ack

If this field is set the server does not expect acknowledgements for messages. That is, when a message
is delivered to the client the server assumes the delivery will succeed and immediately dequeues it.
This functionality may increase performance but at the cost of reliability. Messages can get lost if
a client dies before they are delivered to the application.

=item exclusive

Request exclusive consumer access, meaning only this consumer can access the queue.

=back

=head2 cancel

  $channel->cancel(consumer_tag => 'amq.ctag....')->deliver;

End a queue consumer.

This method cancels a consumer. This does not affect already delivered messages, but
it does mean the server will not send any more messages for that consumer. The client
may receive an arbitrary number of messages in between sending the cancel method and
receiving the cancel-ok reply.

Following arguments are accepted:

=over 2

=item consumer_tag

Holds the consumer tag specified by the client or provided by the server.

=back

=head2 get

  my $get = $channel->get(queue => 'mq')
  $get->deliver;

Direct access to a queue.

This method provides a direct access to the messages in a queue using
a synchronous dialogue that is designed for specific types of application
where synchronous functionality is more important than performance.

This is simple event emitter to which you have to subscribe. It can emit:

=over 2

=item message

Provide client with a message.

This method delivers a message to the client following a get method. A message
delivered by 'get-ok' must be acknowledged unless the no-ack option was set
in the get method.

You can access all get-ok reply parameters as below:

  $get->on(message => sub {
    my $get = shift;
    my $get_ok = shift;
    my $message = shift;

    say "Still got: " . $get_ok->method_frame->message_count;
  });

=item empty

Indicate no messages available.

This method tells the client that the queue has no messages available for the
client.

=back

Following arguments are accepted:

=over 2

=item queue

Specifies the name of the queue to get a message from.

=item no_ack

If this field is set the server does not expect acknowledgements for messages. That is, when a message
is delivered to the client the server assumes the delivery will succeed and immediately dequeues it.
This functionality may increase performance but at the cost of reliability. Messages can get lost if
a client dies before they are delivered to the application.

=back

=head2 ack

  $channel->ack(delivery_tag => 1);

Acknowledge one or more messages.

When sent by the client, this method acknowledges one or more messages
delivered via the Deliver or Get-Ok methods. When sent by server, this
method acknowledges one or more messages published with the Publish
method on a channel in confirm mode. The acknowledgement can be for
a single message or a set of messages up to and including a specific
message.

Following arguments are accepted:

=over 2

=item delivery_tag

Server assigned delivery tag that was received with a message.

=item multiple

If set to 1, the delivery tag is treated as "up to and including", so
that multiple messages can be acknowledged with a single method. If set
to zero, the delivery tag refers to a single message. If the multiple
field is 1, and the delivery tag is zero, this indicates acknowledgement
of all outstanding messages.

=back

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

  $channel->recover(requeue => 0)->deliver;

Redeliver unacknowledged messages.

This method asks the server to redeliver all unacknowledged messages
on a specified channel. Zero or more messages may be redelivered.

=over 2

=item requeue

If this field is zero, the message will be redelivered to the original
recipient. If this bit is 1, the server will attempt to requeue the
message, potentially then delivering it to an alternative subscriber.

=back

=head2 reject

  $channel->reject(delivery_tag => 1, requeue => 0)->deliver;

Reject an incoming message.

This method allows a client to reject a message. It can be
used to interrupt and cancel large incoming messages, or
return untreatable messages to their original queue.

Following arguments are accepted:

=over 2

=item delivery_tag

Server assigned delivery tag that was received with a message.

=item requeue

If requeue is true, the server will attempt to requeue the message.
If requeue is false or the requeue attempt fails the messages are
discarded or dead-lettered.

=back

=head2 select_tx

Work with transactions.

The Tx class allows publish and ack operations to be batched into atomic units of work.
The intention is that all publish and ack requests issued within a transaction will
complete successfully or none of them will. Servers SHOULD implement atomic transactions
at least where all publish or ack requests affect a single queue. Transactions that cover
multiple queues may be non-atomic, given that queues can be created and destroyed
asynchronously, and such events do not form part of any transaction.
Further, the behaviour of transactions with respect to the immediate and mandatory flags
on Basic.Publish methods is not defined.

  $channel->select_tx()->deliver;

Select standard transaction mode.

This method sets the channel to use standard transactions. The client must use this method
at least once on a channel before using the Commit or Rollback methods.

=head2 commit_tx

  $channel->commit_tx()->deliver;

Commit the current transaction.

This method commits all message publications and acknowledgments performed in the current
transaction. A new transaction starts immediately after a commit.

=head2 rollback_tx

  $channel->rollback_tx()->deliver;

Abandon the current transaction.

This method abandons all message publications and acknowledgments performed in the current
transaction. A new transaction starts immediately after a rollback. Note that unacked messages
will not be automatically redelivered by rollback; if that is required an explicit recover
call should be issued.

=head1 SEE ALSO

L<Mojo::RabbitMQ::Client>, L<Mojo::RabbitMQ::Method>, L<Net::AMQP::Protocol::v0_8>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2015, Sebastian Podjasek

Based on L<AnyEvent::RabbitMQ> - Copyright (C) 2010 Masahito Ikuta, maintained by C<< bobtfish@bobtfish.net >>

This program is free software, you can redistribute it and/or modify it under the terms of the Artistic License version 2.0.

=cut
