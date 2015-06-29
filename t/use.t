use strict;
use Test::More tests => 5;

BEGIN {
    use_ok 'Mojo::RabbitMQ::Client';
    use_ok 'Mojo::RabbitMQ::Channel';
    use_ok 'Mojo::RabbitMQ::LocalQueue';
    use_ok 'Mojo::RabbitMQ::Method';
    use_ok 'Mojo::RabbitMQ::Method::Publish';
}
