package Redis::NaiveBayes;
{
  $Redis::NaiveBayes::VERSION = '0.0.2';
}
# ABSTRACT: A generic Redis-backed NaiveBayes implementation


use strict;
use warnings;
use List::Util qw(sum reduce);

use Redis;

use constant {
    LABELS => 'labels',
};

# Lua scripts
my $LUA_FLUSH = q{
    -- KEYS:
    --   1: LABELS set
    --   2-N: LABELS set contents

    -- Delete all label stat hashes
    for index, label in ipairs(KEYS) do
        if index > 1 then
            redis.call('del', label)
        end
    end

    -- Delete the LABELS set
    redis.call('del', KEYS[1]);
};

my $LUA_TRAIN = q{
    -- KEYS:
    --   1: LABELS set
    --   2: label being updated
    -- ARGV:
    --   1: raw label name being trained
    --   2: number of tokens being updated
    --   3-X: token being updated
    --   X+1-N: value to increment corresponding token

    redis.call('sadd', KEYS[1], ARGV[1])

    local label      = KEYS[2]
    local num_tokens = ARGV[2]

    for index, token in ipairs(ARGV) do
        if index > num_tokens + 2 then
            break
        end
        if index > 2 then
            redis.call('hincrby', label, token, ARGV[index + num_tokens])
        end
    end
};

my $LUA_UNTRAIN = q{
    -- KEYS:
    --   1: LABELS set
    --   2: label being updated
    -- ARGV:
    --   1: raw label name being untrained
    --   2: number of tokens being updated
    --   3-X: token being updated
    --   X+1-N: value to increment corresponding token

    local label      = KEYS[2]
    local num_tokens = ARGV[2]

    for index, token in ipairs(ARGV) do
        if index > num_tokens + 2 then
            break
        end
        if index > 2 then
            local current = redis.call('hget', label, token);

            if (current and current - ARGV[index + num_tokens] > 0) then
                redis.call('hincrby', label, token, -1 * ARGV[index + num_tokens])
            else
                redis.call('hdel', label, token)
            end
        end
    end

    local total = 0
    for index, value in ipairs(redis.call('hvals', label)) do
        total = total + value
    end

    if total <= 0 then
        redis.call('del', label)
        redis.call('srem', KEYS[1], ARGV[1])
    end
};

my $LUA_SCORES = q{
    -- KEYS
    --   1-N: all possible labels
    -- ARGV
    --   1: correction
    --   2: number of tokens
    --   3-X: tokens
    --   X+1-N: values for each token
    -- FIXME: Maybe I shouldn't care about redis-cluster?
    -- FIXME: I'm ignoring the scores per token on purpose for now

    local scores = {}
    local correction = ARGV[1]
    local num_tokens = ARGV[2]

    for index, label in ipairs(KEYS) do
        local tally = 0
        for _, value in ipairs(redis.call('hvals', label)) do
            tally = tally + value
        end

        if tally > 0 then
            scores[label] = 0.0

            for idx, token in ipairs(ARGV) do
                if idx > num_tokens + 2 then
                    break
                end

                if idx > 2 then
                    local score = redis.call('hget', label, token);

                    if (not score or score == 0) then
                        score = correction
                    end

                    scores[label] = scores[label] + math.log(score / tally)
                end
            end
        end
    end

    -- this is so fucking retarded. I now regret this luascript branch idea
    local return_crap = {};
    local index = 1
    for key, value in pairs(scores) do
        return_crap[index] = key
        return_crap[index+1] = value
        index = index + 2
    end

    return return_crap;
};


sub new {
    my ($class, %args) = @_;
    my $self = bless {}, $class;

    $self->{redis}      = $args{redis}      || Redis->new(%args);
    $self->{correction} = $args{correction} || 0.001;
    $self->{namespace}  = $args{namespace}  or die "Missing namespace";
    $self->{tokenizer}  = $args{tokenizer}  or die "Missing tokenizer";

    $self->_load_scripts;

    return $self;
}

sub _load_scripts {
    my ($self) = @_;

    $self->{scripts} = {};

    ($self->{scripts}->{flush}) = $self->{redis}->script_load($LUA_FLUSH);
    ($self->{scripts}->{train}) = $self->{redis}->script_load($LUA_TRAIN);
    ($self->{scripts}->{untrain}) = $self->{redis}->script_load($LUA_UNTRAIN);
    ($self->{scripts}->{scores}) = $self->{redis}->script_load($LUA_SCORES);
}

sub _exec {
    my ($self, $command, $key, @rest) = @_;

    return $self->{redis}->$command($self->{namespace} . $key, @rest);
}

sub _run_script {
    my ($self, $script, $numkeys, @rest) = @_;

    my $sha1 = $self->{scripts}->{$script} or die "Script wasn't loaded: '$script'";

    $self->{redis}->evalsha($sha1, $numkeys, @rest);
}


sub flush {
    my ($self) = @_;

    my @keys = (LABELS);
    push @keys, ($self->_labels);
    $self->_run_script('flush', scalar @keys, map { $self->{namespace} . $_ } @keys);
}

sub _mrproper {
    my ($self) = @_;

    my @keys = $self->{redis}->keys($self->{namespace} . '*');
    $self->{redis}->del(@keys) if @keys;
}

sub _train {
    my ($self, $label, $item, $script) = @_;

    my @keys = ($self->{namespace} . LABELS, $self->{namespace} . $label);
    my @argv = ($label);

    my $occurrences = $self->{tokenizer}->($item);
    die "tokenizer() didn't return a HASHREF" unless ref $occurrences eq 'HASH';

    push @argv, (scalar keys %$occurrences), keys %$occurrences, values %$occurrences;

    $self->_run_script($script, scalar @keys, @keys, @argv);

    return $occurrences;
}


sub train {
    my ($self, $label, $item) = @_;

    return $self->_train($label, $item, 'train');
}


sub untrain {
    my ($self, $label, $item) = @_;

    return $self->_train($label, $item, 'untrain');
}


sub classify {
    my ($self, $item) = @_;

    my $scores = $self->scores($item);

    my $best_label = reduce { $scores->{$a} > $scores->{$b} ? $a : $b } keys %$scores;

    return $best_label;
}


sub scores {
    my ($self, $item) = @_;

    my $occurrences = $self->{tokenizer}->($item);
    die "tokenizer() didn't return a HASHREF" unless ref $occurrences eq 'HASH';

    my @labels = map { $self->{namespace} . $_ } ($self->_labels);
    my @argv = ($self->{correction}, scalar keys %$occurrences, keys %$occurrences, values %$occurrences);

    my %scores = $self->_run_script('scores', scalar @labels, @labels, @argv);

    return { map { substr($_, length($self->{namespace})) => $scores{$_} } keys %scores };
}

sub _labels {
    my ($self) = @_;

    return $self->_exec('smembers', LABELS);
}

sub _priors {
    my ($self, $label) = @_;

    my %data = $self->_exec('hgetall', $label);
    return { %data };
}


1;

__END__

=pod

=head1 NAME

Redis::NaiveBayes - A generic Redis-backed NaiveBayes implementation

=head1 VERSION

version 0.0.2

=head1 SYNOPSIS

    my $tokenizer = sub {
        my $input = shift;

        my %occurs;
        $occurs{$_}++ for split(/\s/, lc $input);

        return \%occurs;
    };

    my $bayes = Redis::NaiveBayes->new(
        namespace => 'playground:',
        tokenizer => \&tokenizer,
    );

=head1 DESCRIPTION

This distribution provides a very simple NaiveBayes classifier
backed by a Redis instance. It uses the evalsha functionality
available since Redis 2.6.0 to try to speed things up while
avoiding some obvious race conditions during the untrain() phase.

The goal of Redis::NaiveBayes is to keep dependencies at
minimum while being as generic as possible to allow any sort
of usage. By design, it doesn't provide any sort of tokenization
nor filtering out of the box.

=head1 METHODS

=head2 new

    my $bayes = Redis::NaiveBayes->new(
        namespace  => 'playground:',
        tokenizer  => \&tokenizer,
        correction => 0.1,
        redis      => $redis_instance,
    );

Instantiates a L<Redis::NaiveBayes> instance using the provided
C<correction>, C<namespace> and C<tokenizers>.

If provided, it also uses a L<Redis> instance (C<redis> parameter)
instead of instantiating one by itself.

A tokenizer is any subroutine that returns a HASHREF of occurrences
in the item provided for train()ining or classify()ing.

=head2 flush

    $bayes->flush;

Cleanup all the possible keys this classifier instance could've
touched. If you want to clean everything under the provided namespace,
call _mrproper() instead, but beware that it will delete all the
keys that match C<namespace*>.

=head2 train

    $bayes->train("ham", "this is a good message");
    $bayes->train("spam", "price from Nigeria needs your help");

Trains as a label ("ham") the given item. The item can be any arbitrary
structure as long as the provided C<tokenizer> understands it.

=head2 untrain

    $bayes->untrain("ham", "I don't thing this message is good anymore")

The opposite of train().

=head2 classify

    my $label = $bayes->classify("Nigeria needs help");
    >>> "spam"

Gets the most probable category the provided item in is.

=head2 scores

    my $scores = $bayes->scores("any sort of message");

Returns a HASHREF with the scores for each of the labels known by the model

=head1 NOTES

This module is heavilly inspired by the Python implementation
available at https://github.com/jart/redisbayes - the main
difference, besides the obvious language choice, is that
Redis::NaiveBayes focuses on being generic and minimizing
the number of roundtrips to Redis.

=head1 TODO

=over

=item Add support for additive smoothing

=back

=head1 SEE ALSO

L<Redis>, L<Redis::Bayes>, L<Algorithm::NaiveBayes>

=encoding utf8

=head1 AUTHOR

Caio Romão <cpan@caioromao.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2013 by Caio Romão.

This is free software, licensed under:

  The MIT (X11) License

=cut
