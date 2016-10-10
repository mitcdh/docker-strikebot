# Docker Urbandead StrikeBot

Docker image of strikebot, the one true papa of the [Ridleybank Resistance Front](http://wiki.urbandead.com/index.php/The_Ridleybank_Resistance_Front) and also a generic IRC bot for coordinating zombie strikes on [urbandead.com](urbandead.com)

### Environment Variables

* `NICK`: Username/IRC Name/Nick 
* `NS_PASS`: Nickserv password
* `SERVER`: IRC server to connect to
* `OWNER_CHANNELS`: Prints all stored targets to these channels
* `CHANNELS`: Comma deliminated list of auto-join channels and optional passwords


### Usage
````bash
docker run -d \
    --name strikebot \
    -e NICK="StrikeBot" \
    -e NS_PASS="" \
    -e SERVER="irc.nexuswar.com" \
    -e OWNER_CHANNEL="#rrf-wc" \
    -e CHANNELS="#rrf-ud,#rrf-wc PASSWORD,#gore PASSWORD,#constable" \
    mitcdh/strikebot
````

### Structure
* `/usr/src/strikebot`: StrikeBot's home

