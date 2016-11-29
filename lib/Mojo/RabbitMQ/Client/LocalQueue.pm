package Mojo::RabbitMQ::Client::LocalQueue;
use Mojo::Base -base;

has message_queue    => sub { [] };
has drain_code_queue => sub { [] };

sub push {
  my $self = shift;

  CORE::push @{$self->message_queue}, @_;
  return $self->_drain_queue();
}

sub get {
  my $self = shift;

  CORE::push @{$self->drain_code_queue}, @_;
  return $self->_drain_queue();
}

sub _drain_queue {
  my $self = shift;

  my $message_count    = scalar @{$self->message_queue};
  my $drain_code_count = scalar @{$self->drain_code_queue};

  my $count
    = $message_count < $drain_code_count ? $message_count : $drain_code_count;

  for (1 .. $count) {
    &{shift @{$self->drain_code_queue}}(shift @{$self->message_queue});
  }

  return $self;
}

1;

=encoding utf8

=head1 NAME

Mojo::RabbitMQ::Client::LocalQueue - Callback queue

=head1 SYNOPSIS

  use Mojo::RabbitMQ::Client::LocalQueue

  my $queue = Mojo::RabbitMQ::Client::LocalQueue->new();

  # Register callback when content appears
  $queue->get(sub { say "got expected content: " . $_[0] });

  # Push some content to consume
  $queue->push("It Works!");

  # This prints:
  # got expected content: It Works!

=head1 DESCRIPTION

L<Mojo::RabbitMQ::Client::LocalQueue> is a queue for callbacks expecting some content to be received.

=head1 METHODS

L<Mojo::RabbitMQ::Client::LocalQueue> implements following methods:

=head2 get

  $queue->get(sub { process_message($_[0]) })

Registers a callback which is executed when new message is pushed to queue.

=head2 push

  $queue->push("Some content");
  $queue->push({objects => 'are also welcome});

Pushes content to queue and also drains all declared callbacks.

=head1 SEE ALSO

L<Mojo::RabbitMQ::Client>, L<Mojo::RabbitMQ::Client::Channel>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2015, Sebastian Podjasek

Based on L<AnyEvent::RabbitMQ::LocalQueue> - Copyright (C) 2010 Masahito Ikuta, maintained by C<< bobtfish@bobtfish.net >>

This program is free software, you can redistribute it and/or modify it under the terms of the Artistic License version 2.0.

=cut
