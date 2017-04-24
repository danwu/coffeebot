require 'slack-ruby-bot'
require 'pry'

MEMBER_LIST_CHANNEL = 'random-coffee'
CONVERSATIONS = [] #initiator_id, last_responder_asked_at, responder_ids, channel_member_ids

$static_client = nil

def is_active_responder(member_id)
  CONVERSATIONS.find { |conversation| conversation[:responder_ids].last == member_id }
end

def slack_client
  $static_client ||= Slack::Web::Client.new
end

def user_name_from_id(user_id)
  user_info = slack_client.users_info(user: user_id)
  user_info['user']['real_name']
end

def declined_response(conversation, responder_id)
  conversation[:channel_member_ids].delete(responder_id)
  if conversation[:channel_member_ids].length > 0  && conversation[:responder_ids].length < 3
    ask_next_responder(conversation)
  else
    no_match_found(conversation)
  end
end

def pick_match_id(conversation)
  #TODO: get status for everyone and only get online ones
  pick = nil
  100.times {
    potential_pick = (conversation[:channel_member_ids] - [conversation[:initiator_id]] - conversation[:responder_ids]).sample
    break unless potential_pick

    if is_available(potential_pick)
      pick = potential_pick
      break
    end
  }
  pick
end

def is_available(user_id)
  !slack_client.users_info(user: user_id)["user"]["is_bot"] && slack_client.users_getPresence(user: user_id)["presence"] == "active"
end

def ask_next_responder(conversation)
  matched_user_id = pick_match_id(conversation)

  if matched_user_id
    #check if user has been already picked, then try again
    conversation[:last_responder_asked_at] = Time.now()

    if conversation[:responder_ids]
      conversation[:responder_ids] << matched_user_id
    else
      conversation[:responder_ids] = [matched_user_id]
    end

    direct_message(matched_user_id, "Are you open for a random brew today?")
  else
    no_match_found(conversation)
  end
end

def direct_message(user_id, text)
  slack_client = Slack::Web::Client.new
  channel_id = slack_client.im_open(user: user_id)["channel"]["id"]
  user_name = user_name_from_id(user_id)
  slack_client.chat_postMessage(channel: channel_id, text: text)
  puts "messaged #{user_name} in #{channel_id}"
end

def notify_matched_pair(conversation, responder_id)
  slack_client = Slack::Web::Client.new
  initiator_id = conversation[:initiator_id]
  CONVERSATIONS.delete(conversation)
  mpim_id = slack_client.mpim_open(users: "#{initiator_id},#{responder_id}")["group"]["id"]
  slack_client.chat_postMessage(channel: mpim_id, text: ":boom: Looks like both of you are available for coffee today. Here's a question to kick off the conversation: \n >#{random_question}")
end

def no_match_found(conversation)
  direct_message(conversation[:initiator_id], "Sorry, no match found. Try again later.")
  CONVERSATIONS.delete(conversation)
end

def random_question
  [
    "What is you most prized possession?",
    "What is your dream job?",
    "What do you want to improve?"
  ].sample
end

class Bot < SlackRubyBot::Bot
  help do
    title "Coffee Bot"
    desc "Arranges random coffee"

    command "coffee" do
      desc "you're free for coffee today? Great, I'll find someone to pair you up."
    end
  end

  command 'coffee' do |client, data, _match|
    slack_client = Slack::Web::Client.new
    initiator_id = data["user"]
    if CONVERSATIONS.detect { |conversation| conversation[:initiator_id] == initiator_id }
      client.say(text: "Still waiting on your previous request #{user_name_from_id(initiator_id)}", channel: data.channel)
    else
      channel_list = slack_client.channels_list
      channel = channel_list["channels"].find { |c| c["name"] == MEMBER_LIST_CHANNEL }
      channel_id = channel["id"]
      channel_info = slack_client.channels_info(channel: channel_id)
      channel_member_ids = channel_info["channel"]["members"]

      conversation = { initiator_id: initiator_id, responder_ids: [], channel_member_ids: channel_member_ids }
      ask_next_responder(conversation)
      CONVERSATIONS << conversation
      client.say(text: "Great! I will go see if anyone is available! \nBe back in no longer than 15 minutes.", channel: data.channel)
    end
  end

  command 'cancel' do |client, data, _match|
    user_id = data["user"]
    found_conversation = CONVERSATIONS.find { |conversation| conversation[:initiator_id] == user_id }
    if found_conversation
      CONVERSATIONS.delete found_conversation
    else
      direct_message(user_id, "I didn't find an outstanding coffee request #{user_name_from_id(user_id)}")
    end
  end

  command 'yes' do |client, data, _match|
    responder_id = data["user"]
    conversation = is_active_responder(responder_id)
    if conversation
      notify_matched_pair(conversation, responder_id)
    else
      client.say(text: "Was I saying something?", channel: data.channel)
    end
  end

  command 'no' do |client, data, _match|
    responder_id = data["user"]
    conversation = is_active_responder(responder_id)
    if conversation
      client.say(text: "Okay, no worries. If you want to grab coffee with someone you might not normally see, say `coffee` :smile:", channel: data.channel)
      declined_response(conversation, responder_id)
    else
      client.say(text: "Sorry, I didn't want to keep the other person waiting. Say `coffee` if you want to find a coffee pair", channel: data.channel)
    end
  end

  match '.*' do |client, data, _match|
    client.say(text: "If you’d like me to find someone who’s available for coffee, type …`coffee`.", channel: data.channel)
  end
end


Thread.new {
  loop {
    CONVERSATIONS.each { |conversation|
      if conversation[:last_responder_asked_at] < (Time.now - 200)
        puts "conversation with #{user_name_from_id(conversation[:initiator_id])} timed out, asking next user"
        ask_next_responder(conversation)
      end
    }
    sleep 5
  }
}

SlackRubyBot::Client.logger.level = Logger::WARN
Bot.run
