package Mojo::RabbitMQ::Client;
use Mojo::Base 'Mojo::EventEmitter';
use Carp qw(croak confess);
use Mojo::URL;
use Mojo::Home;
use Mojo::IOLoop;
use Mojo::Parameters;
use Mojo::Promise;
use Mojo::Util qw(url_unescape dumper);
use List::Util qw(none);
use Scalar::Util qw(blessed);
use File::Basename 'dirname';
use File::ShareDir qw(dist_file);

use Net::AMQP;
use Net::AMQP::Common qw(:all);

use Mojo::RabbitMQ::Client::Channel;
use Mojo::RabbitMQ::Client::Consumer;
use Mojo::RabbitMQ::Client::LocalQueue;
use Mojo::RabbitMQ::Client::Publisher;

our $VERSION = "0.0.9";

use constant DEBUG => $ENV{MOJO_RABBITMQ_DEBUG} // 0;

has is_open => 0;
has url     => undef;
has tls     => sub { shift->_uri_handler('tls') };
has user    => sub { shift->_uri_handler('user') };
has pass    => sub { shift->_uri_handler('pass') };
has host    => sub { shift->_uri_handler('host') };
has port    => sub { shift->_uri_handler('port') };
has vhost   => sub { shift->_uri_handler('vhost') };
has params  => sub { shift->_uri_handler('params') // Mojo::Parameters->new };
has connect_timeout   => sub { $ENV{MOJO_CONNECT_TIMEOUT} // 10 };
has heartbeat_timeout => 60;
has heartbeat_received => 0;    # When did we receive last heartbeat
has heartbeat_sent     => 0;    # When did we sent last heartbeat
has ioloop          => sub { Mojo::IOLoop->singleton };
has max_buffer_size => 16384;
has max_channels    => 0;
has queue    => sub { Mojo::RabbitMQ::Client::LocalQueue->new };
has channels => sub { {} };
has stream_id => undef;

sub connect {
  my $self = shift;
  $self->{buffer} = '';

  my $id;
  $id = $self->_connect(sub { $self->_connected($id) });
  $self->stream_id($id);

  return $id;
}

sub connect_p {
  my $self = shift;
  my $promise = Mojo::Promise->new;

  my $id;

  weaken $self;
  my $handler = sub {
    my ($err) = @_;
    if (defined $err) {
      return $promise->reject($err);
    }

    return $promise->resolve($self);
  };

  $id = $self->_connect(sub { $self->_connected($id, $handler) });
  $self->stream_id($id);

  return $promise;
}

sub consumer {
  my ($class, @params) = @_;
  croak "consumer is a static method" if ref $class;

  return Mojo::RabbitMQ::Client::Consumer->new(@params);
}

sub publisher {
  my ($class, @params) = @_;
  croak "publisher is a static method" if ref $class;

  return Mojo::RabbitMQ::Client::Publisher->new(@params);
}

sub param {
  my $self = shift;
  return undef unless defined $self->params;
  return $self->params->param(@_);
}

sub add_channel {
  my $self    = shift;
  my $channel = shift;

  my $id = $channel->id;
  if ($id and $self->channels->{$id}) {
    return $channel->emit(
      error => 'Channel with id: ' . $id . ' already defined');
  }

  if ($self->max_channels > 0
    and scalar keys %{$self->channels} >= $self->max_channels)
  {
    return $channel->emit(error => 'Maximum number of channels reached');
  }

  if (not $id) {
    for my $candidate_id (1 .. (2**16 - 1)) {
      next if defined $self->channels->{$candidate_id};
      $id = $candidate_id;
      last;
    }
    unless ($id) {
      return $channel->emit(error => 'Ran out of channel ids');
    }
  }

  $self->channels->{$id} = $channel->id($id)->client($self);

  return $channel;
}

sub acquire_channel {
  my $self = shift;

  my $promise = Mojo::Promise->new;

  my $channel = Mojo::RabbitMQ::Client::Channel->new();
  $channel->catch(sub { $promise->reject(@_) });
  $channel->on(close => sub { warn "Channel closed" });
  $channel->on(open => sub { $promise->resolve(@_) });

  return $promise;
}

sub open_channel {
  my $self    = shift;
  my $channel = shift;

  return $channel->emit(error => 'Client connection not opened')
    unless $self->is_open;

  $self->add_channel($channel)->open;

  return $self;
}

sub delete_channel {
  my $self = shift;
  return delete $self->channels->{shift};
}

sub close {
  my $self = shift;

  weaken $self;
  $self->_write_expect(
    'Connection::Close'   => {},
    'Connection::CloseOk' => sub {
      $self->emit('close');
      $self->_close;
    },
    sub {
      $self->_close;
    }
  );
}

sub _loop { $_[0]->ioloop }

sub _error {
  my ($self, $id, $err) = @_;

  $self->emit(error => $err);
}

sub _uri_handler {
  my $self = shift;
  my $attr = shift;

  return undef unless defined $self->url;

  $self->url(Mojo::URL->new($self->url))
    unless blessed $self->url && $self->url->isa('Mojo::URL');

  # Set some defaults
  my %defaults = (
    tls    => 0,
    user   => undef,
    pass   => undef,
    host   => 'localhost',
    port   => 5672,
    vhost  => '/',
    params => undef
  );

  # Check secure scheme in url
  $defaults{tls} = 1
    if $self->url->scheme
    =~ /^(amqp|rabbitmq)s$/;    # Fallback support for rabbitmq scheme name
  $defaults{port} = 5671 if $defaults{tls};

  # Get host & port
  $defaults{host} = $self->url->host
    if defined $self->url->host && $self->url->host ne '';
  $defaults{port} = $self->url->port if defined $self->url->port;

  # Get user & password
  my $userinfo = $self->url->userinfo;
  if (defined $userinfo) {
    my ($user, $pass) = split /:/, $userinfo;
    $defaults{user} = $user;
    $defaults{pass} = $pass;
  }

  my $vhost = url_unescape $self->url->path;
  $vhost =~ s|^/(.+)$|$1|;
  $defaults{vhost} = $vhost if defined $vhost && $vhost ne '';

  # Query params
  my $params = $defaults{params} = $self->url->query;

  # Handle common aliases to internal names
  my %aliases = (
    cacertfile           => 'ca',
    certfile             => 'cert',
    keyfile              => 'key',
    fail_if_no_peer_cert => 'verify',
    connection_timeout   => 'timeout'
  );
  $params->param($aliases{$_}, $params->param($_))
    foreach grep { defined $params->param($_) } keys %aliases;

  # Some query parameters are translated to attribute values
  my %attributes = (
    heartbeat_timeout => 'heartbeat',
    connect_timeout   => 'timeout',
    max_channels      => 'channel_max'
  );
  $self->$_($params->param($attributes{$_}))
    foreach grep { defined $params->param($attributes{$_}) } keys %attributes;

  # Set all
  $self->$_($defaults{$_}) foreach keys %defaults;

  return $self->$attr;
}

sub _close {
  my $self = shift;
  $self->_loop->stream($self->stream_id)->close_gracefully;
}

sub _handle {
  my ($self, $id, $close) = @_;

  $self->emit('disconnect');

  $self->_loop->remove($id);
}

sub _read {
  my ($self, $id, $chunk) = @_;
  my $chunk_len = length($chunk);

  warn "<- @{[dumper $chunk]}" if DEBUG;

  if ($chunk_len + length($self->{buffer}) > $self->max_buffer_size) {
    $self->{buffer} = '';
    return;
  }

  my $data = $self->{buffer} .= $chunk;

  if (length($data) < 8) {
    return;
  }

  my ($type_id, $channel, $length,) = unpack 'CnN', substr $data, 0, 7;
  if (!defined $type_id || !defined $channel || !defined $length) {
    $self->{buffer} = '';
    return;
  }

  if (length($data) < $length) {
    return;
  }

  weaken $self;
  $self->_loop->next_tick(sub { $self->_parse_frames });

  return;
}

sub _parse_frames {
  my $self = shift;
  my $data = $self->{buffer};

  my ($type_id, $channel, $length,) = unpack 'CnN', substr $data, 0, 7;

  my $stack = substr $self->{buffer}, 0, $length + 8, '';

  my ($frame) = Net::AMQP->parse_raw_frames(\$stack);

  if ($frame->isa('Net::AMQP::Frame::Heartbeat')) {
    $self->heartbeat_received(time());
  }
  elsif ($frame->isa('Net::AMQP::Frame::Method')
    and $frame->method_frame->isa('Net::AMQP::Protocol::Connection::Close'))
  {
    $self->is_open(0);

    $self->_write_frame(Net::AMQP::Protocol::Connection::CloseOk->new());
    $self->emit(disconnect => "Server side disconnection: "
        . $frame->method_frame->{reply_text});
  }
  elsif ($frame->channel == 0) {
    $self->queue->push($frame);
  }
  else {
    my $channel = $self->channels->{$frame->channel};
    if (defined $channel) {
      $channel->_push_queue_or_consume($frame);
    }
    else {
      $self->emit(
        error => "Unknown channel id received: "
          . ($frame->channel // '(undef)'),
        $frame
      );
    }
  }

  weaken $self;
  $self->_loop->next_tick(sub { $self->_parse_frames })
    if length($self->{buffer}) >= 8;
}

sub _connect {
  my ($self, $cb) = @_;

  # Options
  # Parse according to (https://www.rabbitmq.com/uri-spec.html)
  my $options = {
    address  => $self->host,
    port     => $self->port,
    timeout  => $self->connect_timeout,
    tls      => $self->tls,
    tls_ca   => scalar $self->param('ca'),
    tls_cert => scalar $self->param('cert'),
    tls_key  => scalar $self->param('key')
  };
  my $verify = $self->param('verify');
  $options->{tls_verify} = hex $verify if defined $verify;

  # Connect
  weaken $self;
  my $id;
  return $id = $self->_loop->client(
    $options => sub {
      my ($loop, $err, $stream) = @_;

      # Connection error
      return unless $self;
      return $self->_error($id, $err) if $err;

      $self->emit(connect => $stream);

      # Connection established
      $stream->on(timeout => sub { $self->_error($id, 'Inactivity timeout') });
      $stream->on(close => sub { $self->_handle($id, 1) });
      $stream->on(error => sub { $self && $self->_error($id, pop) });
      $stream->on(read => sub { $self->_read($id, pop) });
      $cb->();
    }
  );
}

sub _connected {
  my ($self, $id, $cb) = @_;

  # Inactivity timeout
  my $stream = $self->_loop->stream($id)->timeout(0);

  # Store connection information in transaction
  my $handle = $stream->handle;

  # Detect that xml spec was already loaded
  my $loaded = eval { Net::AMQP::Protocol::Connection::StartOk->new; 1 };
  unless ($loaded) {    # Load AMQP specs
    my $file = "amqp0-9-1.stripped.extended.xml";

    # Original spec is in "fixed_amqp0-8.xml"
    my $share = dist_file('Mojo-RabbitMQ-Client', $file);
    Net::AMQP::Protocol->load_xml_spec($share);
  }

  $self->_write($id => Net::AMQP::Protocol->header);

  weaken $self;
  $self->_expect(
    'Connection::Start' => sub {
      my $frame = shift;

      my @mechanisms = split /\s/, $frame->method_frame->mechanisms;
      return $self->emit(error => 'AMQPLAIN is not found in mechanisms')
        if none { $_ eq 'AMQPLAIN' } @mechanisms;

      my @locales = split /\s/, $frame->method_frame->locales;
      return $self->emit(error => 'en_US is not found in locales')
        if none { $_ eq 'en_US' } @locales;

      $self->{_server_properties} = $frame->method_frame->server_properties;

      warn "-- Connection::Start {product: " . $self->{_server_properties}->{product} . ", version: " . $self->{_server_properties}->{version} . "}\n" if DEBUG;
      $self->_write_frame(
        Net::AMQP::Protocol::Connection::StartOk->new(
          client_properties => {
            platform    => 'Perl',
            product     => __PACKAGE__,
            information => 'https://github.com/inway/mojo-rabbitmq-client',
            version     => __PACKAGE__->VERSION,
          },
          mechanism => 'AMQPLAIN',
          response  => {LOGIN => $self->user, PASSWORD => $self->pass},
          locale    => 'en_US',
        ),
      );

      $self->_tune($id, $cb);
    },
    sub {
      $self->emit(error => 'Unable to start connection: ' . shift);
    }
  );
}

sub _tune {
  my ($self, $id, $cb) = @_;

  weaken $self;
  $self->_expect(
    'Connection::Tune' => sub {
      my $frame = shift;

      my $method_frame = $frame->method_frame;
      $self->max_buffer_size($method_frame->frame_max);

      my $heartbeat = $self->heartbeat_timeout || $method_frame->heartbeat;

      warn "-- Connection::Tune {frame_max: " . $method_frame->frame_max . ", heartbeat: " . $method_frame->heartbeat . "}\n" if DEBUG;
      # Confirm
      $self->_write_frame(
        Net::AMQP::Protocol::Connection::TuneOk->new(
          channel_max => $method_frame->channel_max,
          frame_max   => $method_frame->frame_max,
          heartbeat   => $heartbeat,
        ),
      );

 # According to https://www.rabbitmq.com/amqp-0-9-1-errata.html
 # The client should start sending heartbeats after receiving a Connection.Tune
 # method, and start monitoring heartbeats after sending Connection.Open.
 # -and-
 # Heartbeat frames are sent about every timeout / 2 seconds. After two missed
 # heartbeats, the peer is considered to be unreachable.
      $self->{heartbeat_tid} = $self->_loop->recurring(
        $heartbeat / 2 => sub {
          return unless time() - $self->heartbeat_sent > $heartbeat / 2;
          $self->_write_frame(Net::AMQP::Frame::Heartbeat->new());
          $self->heartbeat_sent(time());
        }
      ) if $heartbeat;

      $self->_write_expect(
        'Connection::Open' =>
          {virtual_host => $self->vhost, capabilities => '', insist => 1,},
        'Connection::OpenOk' => sub {
          warn "-- Connection::OpenOk\n" if DEBUG;

          $self->is_open(1);
          $self->emit('open');
          $cb->() if defined $cb;
        },
        sub {
          my $err = shift;
          $self->emit(error => 'Unable to open connection: ' . $err);
          $cb->($err) if defined $cb;
        }
      );
    },
    sub {
      $self->emit(error => 'Unable to tune connection: ' . shift);
    }
  );
}

sub _write_expect {
  my $self = shift;
  my ($method, $args, $exp, $cb, $failure_cb, $channel_id) = @_;
  $method = 'Net::AMQP::Protocol::' . $method;

  $channel_id ||= 0;

  $self->_write_frame(
    Net::AMQP::Frame::Method->new(    #
      method_frame => $method->new(%$args)    #
    ),
    $channel_id
  );

  return $self->_expect($exp, $cb, $failure_cb, $channel_id);
}

sub _expect {
  my $self = shift;
  my ($exp, $cb, $failure_cb, $channel_id) = @_;
  my @expected = ref($exp) eq 'ARRAY' ? @$exp : ($exp);

  $channel_id ||= 0;

  my $queue;
  if (!$channel_id) {
    $queue = $self->queue;
  }
  else {
    my $channel = $self->channels->{$channel_id};
    if (defined $channel) {
      $queue = $channel->queue;
    }
    else {
      $failure_cb->(
        "Unknown channel id received: " . ($channel_id // '(undef)'));
    }
  }

  return unless $queue;

  $queue->get(
    sub {
      my $frame = shift;

      return $failure_cb->("Received data is not method frame")
        if not $frame->isa("Net::AMQP::Frame::Method");

      my $method_frame = $frame->method_frame;
      for my $exp (@expected) {
        return $cb->($frame)
          if $method_frame->isa("Net::AMQP::Protocol::" . $exp);
      }

      $failure_cb->("Method is not "
          . join(', ', @expected)
          . ". It's "
          . ref($method_frame));
    }
  );
}

sub _write_frame {
  my $self = shift;
  my $id   = $self->stream_id;
  my ($out, $channel, $cb) = @_;

  if ($out->isa('Net::AMQP::Protocol::Base')) {
    $out = $out->frame_wrap;
  }
  $out->channel($channel // 0);

  return $self->_write($id, $out->to_raw_frame, $cb);
}

sub _write {
  my $self  = shift @_;
  my $id    = shift @_;
  my $frame = shift @_;
  my $cb    = shift @_;

  warn "-> @{[dumper $frame]}" if DEBUG;

  utf8::downgrade($frame);
  $self->_loop->stream($id)->write($frame => $cb)
    if defined $self->_loop->stream($id);
}

sub DESTROY {
  my $self          = shift;
  my $ioloop        = $self->ioloop or return;
  my $heartbeat_tid = $self->{heartbeat_tid};

  $ioloop->remove($heartbeat_tid) if $heartbeat_tid;
}

1;

=encoding utf8

=head1 NAME

Mojo::RabbitMQ::Client - Mojo::IOLoop based RabbitMQ client

=head1 SYNOPSIS

  use Mojo::RabbitMQ::Client;

  # Supply URL according to (https://www.rabbitmq.com/uri-spec.html)
  my $client = Mojo::RabbitMQ::Client->new(
    url => 'amqp://guest:guest@127.0.0.1:5672/');

  # Catch all client related errors
  $client->catch(sub { warn "Some error caught in client"; });

  # When connection is in Open state, open new channel
  $client->on(
    open => sub {
      my ($client) = @_;

      # Create a new channel with auto-assigned id
      my $channel = Mojo::RabbitMQ::Client::Channel->new();

      $channel->catch(sub { warn "Error on channel received"; });

      $channel->on(
        open => sub {
          my ($channel) = @_;
          $channel->qos(prefetch_count => 1)->deliver;

          # Publish some example message to test_queue
          my $publish = $channel->publish(
            exchange    => 'test',
            routing_key => 'test_queue',
            body        => 'Test message',
            mandatory   => 0,
            immediate   => 0,
            header      => {}
          );
          # Deliver this message to server
          $publish->deliver;

          # Start consuming messages from test_queue
          my $consumer = $channel->consume(queue => 'test_queue');
          $consumer->on(message => sub { say "Got a message" });
          $consumer->deliver;
        }
      );
      $channel->on(close => sub { $log->error('Channel closed') });

      $client->open_channel($channel);
    }
  );

  # Start connection
  $client->connect();

  # Start Mojo::IOLoop if not running already
  Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

=head2 CONSUMER

  use Mojo::RabbitMQ::Client;
  my $consumer = Mojo::RabbitMQ::Client->consumer(
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
  $consumer->start();

  Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

=head2 PUBLISHER

  use Mojo::RabbitMQ::Client;
  my $publisher = Mojo::RabbitMQ::Client->publisher(
    url => 'amqp://guest:guest@127.0.0.1:5672/?exchange=mojo&routing_key=mojo'
  );

  $publisher->publish('plain text');

  $publisher->publish(
    {encode => { to => 'json'}},
    routing_key => 'mojo_mq'
  )->then(sub {
    say "Message published";
  })->catch(sub {
    die "Publishing failed"
  })->wait;

=head1 DESCRIPTION

L<Mojo::RabbitMQ::Client> is a rewrite of L<AnyEvent::RabbitMQ> to work on top of L<Mojo::IOLoop>.

=head1 EVENTS

L<Mojo::RabbitMQ::Client> inherits all events from L<Mojo::EventEmitter> and can emit the
following new ones.

=head2 connect

  $client->on(connect => sub {
    my ($client, $stream) = @_;
    ...
  });

Emitted when TCP/IP connection with RabbitMQ server is established.

=head2 open

  $client->on(open => sub {
    my ($client) = @_;
    ...
  });

Emitted AMQP protocol Connection.Open-Ok method is received.

=head2 close

  $client->on(close => sub {
    my ($client) = @_;
    ...
  });

Emitted on reception of Connection.Close-Ok method.

=head2 disconnect

  $client->on(close => sub {
    my ($client) = @_;
    ...
  });

Emitted when TCP/IP connection gets disconnected.

=head1 ATTRIBUTES

L<Mojo::RabbitMQ::Client> has following attributes.

=head2 tls

  my $tls = $client->tls;
  $client = $client->tls(1)

Force secure connection. Default is disabled (C<0>).

=head2 user

  my $user = $client->user;
  $client  = $client->user('guest')

Sets username for authorization, by default it's not defined.

=head2 pass

  my $pass = $client->pass;
  $client  = $client->pass('secret')

Sets user password for authorization, by default it's not defined.

=head2 pass

  my $pass = $client->pass;
  $client  = $client->pass('secret')

Sets user password for authorization, by default it's not defined.

=head2 host

  my $host = $client->host;
  $client  = $client->host('localhost')

Hostname or IP address of RabbitMQ server. Defaults to C<localhost>.

=head2 port

  my $port = $client->port;
  $client  = $client->port(1234)

Port on which RabbitMQ server listens for new connections.
Defaults to C<5672>, which is standard RabbitMQ server listen port.

=head2 vhost

  my $vhost = $client->vhost;
  $client  = $client->vhost('/')

RabbitMQ virtual server to user. Default is C</>.

=head2 params

  my $params = $client->params;
  $client  = $client->params(Mojo::Parameters->new('verify=1'))

Sets additional parameters for connection. Default is not defined.

For list of supported parameters see L</"SUPPORTED QUERY PARAMETERS">.

=head2 url

  my $url = $client->url;
  $client = $client->url('amqp://...');

Sets all connection parameters in one string, according to specification from
L<https://www.rabbitmq.com/uri-spec.html>.

  amqp_URI       = "amqp[s]://" amqp_authority [ "/" vhost ] [ "?" query ]

  amqp_authority = [ amqp_userinfo "@" ] host [ ":" port ]

  amqp_userinfo  = username [ ":" password ]

  username       = *( unreserved / pct-encoded / sub-delims )

  password       = *( unreserved / pct-encoded / sub-delims )

  vhost          = segment

=head2 heartbeat_timeout

  my $timeout = $client->heartbeat_timeout;
  $client     = $client->heartbeat_timeout(180);

Heartbeats are use to monitor peer reachability in AMQP.
Default value is C<60> seconds, if set to C<0> no heartbeats will be sent.

=head2 connect_timeout

  my $timeout = $client->connect_timeout;
  $client     = $client->connect_timeout(5);

Connection timeout used by L<Mojo::IOLoop::Client>.
Defaults to environment variable C<MOJO_CONNECT_TIMEOUT> or C<10> seconds
if nothing else is set.

=head2 max_channels

  my $max_channels = $client->max_channels;
  $client          = $client->max_channels(10);

Maximum number of channels allowed to be active. Defaults to C<0> which
means no implicit limit.

When you try to call C<add_channel> over limit an C<error> will be
emitted on channel saying that: I<Maximum number of channels reached>.

=head1 STATIC METHODS

=head2 consumer

  my $client = Mojo::RabbitMQ::Client->consumer(...)

Shortcut for creating L<Mojo::RabbitMQ::Client::Consumer>.

=head2 publisher

  my $client = Mojo::RabbitMQ::Client->publisher(...)

Shortcut for creating L<Mojo::RabbitMQ::Client::Publisher>.

=head1 METHODS

L<Mojo::RabbitMQ::Client> inherits all methods from L<Mojo::EventEmitter> and implements
the following new ones.

=head2 connect

  $client->connect();

Tries to connect to RabbitMQ server and negotiate AMQP protocol.

=head2 close

  $client->close();

=head2 param

  my $param = $client->param('name');
  $client   = $client->param(name => 'value');

=head2 add_channel

  my $channel = Mojo::RabbitMQ::Client::Channel->new();
  ...
  $channel    = $client->add_channel($channel);
  $channel->open;

=head2 open_channel

  my $channel = Mojo::RabbitMQ::Client::Channel->new();
  ...
  $client->open_channel($channel);

=head2 delete_channel

  my $removed = $client->delete_channel($channel->id);

=head1 SUPPORTED QUERY PARAMETERS

There's no formal specification, nevertheless a list of common parameters
recognized by officially supported RabbitMQ clients is maintained here:
L<https://www.rabbitmq.com/uri-query-parameters.html>.

Some shortcuts are also supported, you'll find them in parenthesis.

Aliases are less significant, so when both are specified only primary
value will be used.

=head2 cacertfile (I<ca>)

Path to Certificate Authority file for TLS.

=head2 certfile (I<cert>)

Path to the client certificate file for TLS.

=head2 keyfile (I<key>)

Path to the client certificate private key file for TLS.

=head2 fail_if_no_peer_cert (I<verify>)

TLS verification mode, defaults to 0x01 on the client-side if a certificate
authority file has been provided, or 0x00 otherwise.

=head2 auth_mechanism

Currently only AMQPLAIN is supported, B<so this parameter is ignored>.

=head2 heartbeat

Sets requested heartbeat timeout, just like C<heartbeat_timeout> attribute.

=head2 connection_timeout (I<timeout>)

Sets connection timeout - see L<connection_timeout> attribute.

=head2 channel_max

Sets maximum number of channels - see L<max_channels> attribute.

=head1 SEE ALSO

L<Mojo::RabbitMQ::Client::Channel>, L<Mojo::RabbitMQ::Client::Consumer>, L<Mojo::RabbitMQ::Client::Publisher>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2015-2017, Sebastian Podjasek and others

Based on L<AnyEvent::RabbitMQ> - Copyright (C) 2010 Masahito Ikuta, maintained by C<< bobtfish@bobtfish.net >>

This program is free software, you can redistribute it and/or modify it under the terms of the Artistic License version 2.0.

=cut
