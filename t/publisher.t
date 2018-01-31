use Test::More tests => 9;

BEGIN {
  use_ok 'Mojo::RabbitMQ::Client';
  use_ok 'Mojo::RabbitMQ::Client::Publisher';
}

SKIP: {
  skip "Not requested by user, set TEST_RMQ=1 environment variable to test", 7 unless $ENV{TEST_RMQ};

  my $run_id        = time();
  my $exchange_name = 'mrc_test_' . $run_id;
  my $queue_name    = 'mrc_test_queue' . $run_id;

  my $url
    = $ENV{MOJO_RABBITMQ_URL}
    || 'amqp://guest:guest@127.0.0.1:5672/?exchange='
    . $exchange_name
    . '&routing_key='
    . $queue_name;

  # setup
  my $client = Mojo::RabbitMQ::Client->new(url => $url);
  $client->connect_p->then(
    sub {
      shift->acquire_channel_p();
    }
  )->then(
    sub {
      shift->declare_exchange_p(
        exchange    => $exchange_name,
        type        => 'topic',
        auto_delete => 1
      );
    }
  )->then(
    sub {
      shift->declare_queue_p(queue => $queue_name, auto_delete => 1);
    }
  )->then(
    sub {
      shift->bind_queue_p(
        exchange    => $exchange_name,
        queue       => $queue_name,
        routing_key => $queue_name,
      );
    }
  )->wait;

  # tests
  my @tests = (
    ['plain text',    'plain text',       'text/plain'],
    ['hash as json',  {json => 'object'}, 'application/json'],
    ['array as json', ['array'],          'application/json'],
  );

  my $publisher = Mojo::RabbitMQ::Client::Publisher->new(url => $url);

  foreach my $t (@tests) {
    $publisher->publish_p($t->[1])->then(sub { pass('published: ' . $t->[0]) })->wait;
  }

  $publisher->publish_p(
    {json         => 'object'},
    {content_type => 'text/plain'},
    routing_key => '#'
  )->then(sub { pass('json published into the void') })->wait;


  # verify
  my $channel;
  Mojo::RabbitMQ::Client->new(url => $url)->connect_p->then(
    sub {
      shift->acquire_channel_p();
    }
  )->then(
    sub {
      $channel = shift;
    }
  )->wait;

  foreach my $t (@tests) {
    $channel->get_p(queue => $queue_name, no_ack => 1)->then(
      sub {
        my $channel = shift;
        my $frame = shift;
        my $message = shift;

        if ($message and $message->{header}->{content_type} eq $t->[2]) {
          pass("received valid content_type: " . $t->[2]);
        } else {
          diag explain $frame;
          diag explain $message;
          pass("received something not valid, expecting " . $t->[2] . " got " . ($message->{header}->{content_type} // '(undef)'));
          # SHOULD fail
        }
      }
    )->wait;
  }

  # There should be nothing else waiting
  $channel->get_p(queue => $queue_name, no_ack => 1)->then(
    sub {
      my $channel = shift;
      diag explain \@_;
      pass("received something extra") if defined $_[1]; # SHOULD fail
    }
  )->wait;
}

__END__
my $channel = Mojo::RabbitMQ::Client->new(url => $url)->connect_p->then(sub { shift->acquire_channel_p() }->wait;

foreach my $t (@tests) {
  my ($channel, $frame, $message) = $channel->get_p(queue => $queue_name, no_ack => 1)->wait;

  if ($message and $message->{header}->{content_type} eq $t->[2]) {
    pass("received valid content_type");
  } else {
    fail("received something not valid");
  }
}
