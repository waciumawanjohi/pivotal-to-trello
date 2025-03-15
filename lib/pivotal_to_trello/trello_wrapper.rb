# frozen_string_literal: true

require 'trello'
require 'progress_bar'

module PivotalToTrello
  # Interface to the Trello API.
  class TrelloWrapper
    # Constructor
    def initialize(key, token)
      Trello.configure do |config|
        config.developer_public_key = key
        config.member_token         = token
      end
    end

    def add_logger(logger)
      @logger ||= logger
    end

    # Creates a card in the given list if one with the same name doesn't already exist.
    def create_card(list_id, pivotal_story, pos)
      card   = get_card(list_id, pivotal_story.name, pivotal_story.description)
      card ||= begin
        @logger.puts "Creating a card for #{pivotal_story.story_type} '#{pivotal_story.name}'."
        card = retry_with_exponential_backoff( Proc.new {
          Trello::Card.create(
            name:    pivotal_story.name,
            desc:    pivotal_story.description,
            list_id: list_id,
            pos:     pos,
          )
        })

        card
      end

      create_comments(card, pivotal_story)
      create_tasks(card, pivotal_story)
      create_card_members(card, pivotal_story)
      create_story_labels(card, pivotal_story)
      create_points_labels(card, pivotal_story)

      key                  = card_hash(card.name, card.desc)
      @cards             ||= {}
      @cards[list_id]    ||= {}
      @cards[list_id][key] = card
    end

    # Returns a hash of available boards, keyed on board ID.
    def board_choices
      Trello::Board.all.each_with_object({}) do |board, hash|
        hash[board.id] = board.name
      end
    end

    # Returns a hash of available lists for the given board, keyed on board ID.
    def list_choices(board_id)
      # Cache the list to improve performance.
      @lists           ||= {}
      @lists[board_id] ||= begin
        choices = Trello::Board.find(board_id).lists.each_with_object({}) do |list, hash|
          hash[list.id] = list.name
        end
        choices = Hash[choices.sort_by { |_, v| v }]
        choices[false] = "[don't import these stories]"
        choices
      end

      @lists[board_id]
    end

    # Returns a list of all cards in the given list, keyed on name.
    def cards_for_list(list_id)
      @cards          ||= {}
      @cards[list_id] ||= Trello::List.find(list_id).cards.each_with_object({}) do |card, hash|
        hash[card_hash(card.name, card.desc)] = card
      end

      @cards[list_id]
    end

    # Adds the given label to the card.
    def add_label(card, label_name, label_color)
      @labels                ||= {}
      @labels[card.board_id] ||= Trello::Board.find(card.board_id).labels
      label                    = @labels[card.board_id].find { |l| l.name == label_name && l.color == label_color }
      label                  ||= Trello::Label.create(name: label_name, board_id: card.board_id, color: label_color)

      card.add_label(label) unless card.labels.detect { |l| l.id == label.id }
    end

    # Returns a list of colors that can be used to label cards.
    def label_choices
      {
        "yellow" => "Yellow",
        "purple" => "Purple",
        "blue" => "Blue",
        "red" => "Red",
        "green" => "Green",
        "orange" => "Orange",
        "black" => "Black",
        "sky" => "Sky",
        "pink" => "Pink",
        "lime" => "Lime",
        false    => '[do not create this label]',
      }
    end

    def deletion_choices
      {
        true => "Yes, DELETE EVERY CARD in the Trello board before beginning the import",
        false => "No, do not any Trello cards",
      }
    end

    def delete_all_cards(board_id)
      list_ids = list_choices(board_id).keys
      list_ids.each do |list_id|
        next unless list_id
        list = Trello::List.find(list_id)
        cards = list.cards
        next if cards.empty?
        progress_bar = ProgressBar.new(cards.length)
        progress_bar.puts "Deleting cards from #{list.name}"
        list.cards.each do |card|
          progress_bar.puts "Deleting: #{card.name}"
          card.delete
          progress_bar.increment!
        end
      end
    end

    private

    # Copies notes from the pivotal story to the card.
    def create_comments(card, pivotal_story)
      @logger.puts "Creating comments for card: '#{card.name}'"
      if card.respond_to?(:comments)
        existing_comments = card.comments.map { |c| c.text}
      end
      pivotal_story.comments.each do |comment|
        next if comment.text.to_s.strip.empty?
        candidate_comment = comment.text.to_s.strip.to_s
        next if existing_comments && existing_comments.include?(candidate_comment)
        retry_with_exponential_backoff( Proc.new {card.add_comment(candidate_comment) })
      end
    end

    # Copies notes from the pivotal story to the card.
    def create_tasks(card, pivotal_story)
      @logger.puts "Creating tasks for card: '#{card.name}'"
      tasks = pivotal_story.tasks
      return if tasks.empty?

      checklist = nil

      if card.respond_to?(:checklists) && !card.checklists.nil?
        checklist = card.checklists.find { |checklist| checklist.name == 'Tasks' }
      end
      if !checklist
        checklist = retry_with_exponential_backoff( Proc.new {Trello::Checklist.create(name: 'Tasks', card_id: card.id) })
        retry_with_exponential_backoff( Proc.new { card.add_checklist(checklist) })
      end

      checklist_task_names = checklist.items.map { |item| item.name }

      tasks.each do |task|
        next if checklist_task_names.include?(task.description)

        @logger.puts " - Creating task '#{task.description}'"
        retry_with_exponential_backoff( Proc.new {checklist.add_item(task.description, task.complete) })
      end
    end

    def create_card_members(card, pivotal_story)
      @logger.puts "Adding members to card: '#{card.name}'"
      if pivotal_story.respond_to?(:owners)
        if card.respond_to?(:members) && !card.members.nil?
          card_member_ids = card.members.map { |member| member.id}
        else
          card_member_ids = []
        end
        pivotal_story.owners.each do |owner|
          candidate_member_id = owner_to_member()[owner.id]
          next if candidate_member_id.nil? || card_member_ids.include?(candidate_member_id)
          add_member(card, candidate_member_id)
        end
      end
    end

    def create_story_labels(card, pivotal_story)
      @logger.puts "Creating adding labels to card: '#{card.name}'"
      if pivotal_story.labels.is_a? Array
        pivotal_story.labels.each do |label|
          add_label(card, label.name, 'pink')
        end
      end
    end

    def create_points_labels(card, pivotal_story)
      @logger.puts "Adding points to card: '#{card.name}'"
      if pivotal_story.respond_to?(:estimate)
        add_label(card, pivotal_story.estimate.to_i.to_s, 'green')
      end
    end

    def owner_to_member()
      # Users can manually alter the code to add map from their Tracker User Id and their Trello Member ID
      o_to_m = {
      }
      o_to_m.default = nil
      o_to_m
    end

    def add_member(card, member_id)
      member = Trello::Member.find(member_id)
      retry_with_exponential_backoff( Proc.new { card.add_member(member) })
    end

    # Returns a unique identifier for this list/name/description combination.
    def card_hash(name, description)
      Digest::SHA1.hexdigest("#{name}_#{description}")
    end

    # Returns a card with the given name and description if it exists in the given list, nil otherwise.
    def get_card(list_id, name, description)
      key = card_hash(name, description)
      cards_for_list(list_id)[key] unless cards_for_list(list_id)[key].nil?
    end

    def retry_with_exponential_backoff(function)
      current_retries = 0
      result = nil
      begin
        result = function.call
      rescue StandardError => e
        should_retry, current_retries = should_retry?(current_retries, e)
        retry if should_retry
      rescue SocketError => e
        should_retry, current_retries = should_retry?(current_retries, e)
        retry if should_retry
      end

      result
    end

    def should_retry?(current_retries, e)
      max_retries = 7
      base_delay = 30
      if current_retries < max_retries
        current_retries += 1
        delay = base_delay * (2 ** (current_retries - 1))
        @logger.puts "Retrying (#{current_retries}/#{max_retries}) after #{delay} seconds due to: #{e.class} - #{e.message}"
        sleep(delay)
        return true, current_retries
      else
        @logger.puts "Maximum number of retries reached. Error: #{e.message}"
        raise e
      end
    end
  end
end
