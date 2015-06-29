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
