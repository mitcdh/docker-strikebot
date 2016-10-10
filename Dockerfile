FROM        perl:latest
MAINTAINER  Mitchell Hewes <me@mitcdh.com>

RUN cpanm POE::Component::IRC

COPY . /usr/src/strikebot
WORKDIR /usr/src/strikebot

CMD [ "perl", "./strikebot.pl" ]