#!/bin/sh
for gemfile in gemfiles/*.gemfile; do
  bundle --no-deployment --gemfile $gemfile
done
