package Mojo::RabbitMQ::Client::Publisher;
use Mojo::Base -base;
use Mojo::Promise;
use Mojo::JSON qw(encode_json);
require Mojo::RabbitMQ::Client;

use constant DEBUG => $ENV{MOJO_RABBITMQ_DEBUG} // 0;

has url      => undef;
has client   => undef;
has channel  => undef;
has setup    => 0;
has defaults => sub { {} };

sub publish_p {
  my $self    = shift;
  my $body    = shift;
  my $headers = {};
  my %args    = ();

  if (ref($_[0]) eq 'HASH') {
    $headers = shift;
  }
  if (@_) {
    %args = (@_);
  }

  my $promise = Mojo::Promise->new()->resolve();

  unless ($self->client) {
    $promise = $promise->then(
      sub {
        warn "-- spawn new client\n" if DEBUG;
        my $client_promise = Mojo::Promise->new();

        my $client = Mojo::RabbitMQ::Client->new(url => $self->url);
        $self->client($client);

        # Catch all client related errors
        $self->client->catch(sub { $client_promise->reject(@_) });

        # When connection is in Open state, open new channel
        $self->client->on(
          open => sub {
            warn "-- client open\n" if DEBUG;
            $client_promise->resolve(@_);
          }
        );

        # Start connection
        $client->connect;

        return $client_promise;
      }
    );
  }

  # Create a new channel with auto-assigned id
  unless ($self->channel) {
    $promise = $promise->then(
      sub {
        warn "-- create new channel\n" if DEBUG;
        my $channel_promise = Mojo::Promise->new();

        my $channel         = Mojo::RabbitMQ::Client::Channel->new();

        $channel->catch(sub { $channel_promise->reject(@_) });

        $channel->on(
          open => sub {
            my ($channel) = @_;
            $self->channel($channel);

            warn "-- channel opened\n" if DEBUG;

            $channel_promise->resolve();
          }
        );
        $channel->on(close => sub { warn 'Channel closed: ' . $_[1]->method_frame->reply_text; });

        $self->client->open_channel($channel);

        return $channel_promise;
      }
    );
  }

  $promise = $promise->then(
    sub {
      warn "-- publish message\n" if DEBUG;
      my $query         = $self->client->url->query;
      my $exchange_name = $query->param('exchange');
      my $routing_key   = $query->param('routing_key');
      my %headers       = (content_type => 'text/plain', %$headers);

      if (ref($body)) {
        $headers{content_type} = 'application/json';
        $body = encode_json $body;
      }

      return $self->channel->publish_p(
        exchange    => $exchange_name,
        routing_key => $routing_key,
        mandatory   => 0,
        immediate   => 0,
        header      => \%headers,
        %args,
        body        => $body
      );
    }
  );

  return $promise;
}

1;

=encoding utf8

=head1 NAME

Mojo::RabbitMQ::Client::Publisher - simple Mojo::RabbitMQ::Client based publisher

=head1 SYNOPSIS

  use Mojo::RabbitMQ::Client::Publisher;
  my $publisher = Mojo::RabbitMQ::Client::Publisher->new(
    url => 'amqp://guest:guest@127.0.0.1:5672/?exchange=mojo&routing_key=mojo'
  );

  $publisher->publish_p(
    {encode => { to => 'json'}},
    routing_key => 'mojo_mq'
  )->then(sub {
    say "Message published";
  })->catch(sub {
    die "Publishing failed"
  })->wait;

=head1 DESCRIPTION



=head1 ATTRIBUTES

L<Mojo::RabbitMQ::Client::Publisher> has following attributes.

=head2 url

Sets all connection parameters in one string, according to specification from
L<https://www.rabbitmq.com/uri-spec.html>.

For detailed description please see L<Mojo::RabbitMQ::Client#url>.

=head1 METHODS

L<Mojo::RabbitMQ::Client::Publisher> implements only single method.

=head2 publish_p

  $publisher->publish_p('simple plain text body');

  $publisher->publish_p({ some => 'json' });

  $publisher->publish_p($body, { header => 'content' }, routing_key => 'mojo', mandatory => 1);

Method signature

  publish_p($body!, \%headers?, *@params)

=over 2

=item body

First argument is mandatory body content of published message.
Any reference passed here will be encoded as JSON and accordingly C<content_type> header
will be set to C<application/json>.

=item headers

If second argument is a HASHREF it will be merged to message headers.

=item params

Any other arguments will be considered key/value pairs and passed to publish method as
arguments overriding everything besides body argument.

So this:

  $publisher->publish($body, { header => 'content' });

can be also written like this:

  $publisher->publish($body, header => { header => 'content' });

But beware - headers get merged, but params override values so when you write this:

  $publisher->publish({ json => 'object' }, header => { header => 'content' });

message will lack C<content_type> header!

=head1 SEE ALSO

L<Mojo::RabbitMQ::Client>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2015-2017, Sebastian Podjasek and others

This program is free software, you can redistribute it and/or modify it under the terms of the Artistic License version 2.0.

=cut
