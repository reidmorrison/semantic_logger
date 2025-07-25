FROM ruby:3.4-alpine

# TODO: This is a very quick and hacky Dockerfile 
# to isolate this from my actual system. 
# This can be expanded later to cover the use
# cases for this particular project. 
# TODO: The current CI tests leverage the ruby setup action 
# in a matrix config. It may instead be useful to include
# rbenv in this container then leverage the Docker container
# in tests. This will allow the local dev and CI environments
# to more easily converge. 
# The matrix can then pass an env var to select the necessary ruby versions
# for each test. 
# For guidance see: https://docs.docker.com/guides/ruby/containerize/

# NOTE: Install all the deps first
# TODO: Some of these may not be necessary. 
# Review. 
RUN apk add --no-cache \
    build-base \
    gcc \
    g++ \
    make \
    libc-dev \
    linux-headers \
    musl-dev

WORKDIR /opt/app

# NOTE: The initial copies and bundle install should be small as possible
# This ensures that unless one of these files changes, a rebuild will not
# trigger Docker cache invalidation for these layers. 
COPY Gemfile /opt/app/
COPY semantic_logger.gemspec /opt/app/
# COPY Gemfile.lock /opt/app/Gemfile.lock
COPY lib/semantic_logger/version.rb /opt/app/lib/semantic_logger/version.rb
RUN gem install bundler && bundle install

# NOTE: Copy the remainder of files into the container. 
COPY . /opt/app/