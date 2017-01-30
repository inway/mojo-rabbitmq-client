requires 'perl', '5.008001';
requires 'Mojolicious', '6.10';
requires 'Net::AMQP', '0.06';
requires 'File::ShareDir';
requires 'List::Util', '1.33';
requires 'File::ShareDir';

on 'test' => sub {
    requires 'Test::More', '0.98';
    requires 'Test::Exception', '0.43';
};
