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

    def add_board(board_id)
      @board_id ||= board_id
      @board ||= Trello::Board.find(@board_id)
      ensure_lists_and_cards_cached
    end

    def ensure_lists_and_cards_cached
      @lists           ||= retry_with_exponential_backoff( Proc.new { @board.lists })
      @card_array = @lists.flat_map { |list| Trello::List.find(list.id).cards.map(&:itself) }
      @cards   ||= @card_array.map { |card| [card_hash(card.name, card.desc), card] }.to_h
    end

    def get_duplicate_trello_cards
      hash_func = ->(card) { card_hash(card.name, card.desc) }
      duplicate_hashes = @card_array.group_by(&hash_func).select { |_, v| v.size > 1 }.keys
      duplicate_cards = @card_array.filter {|card| duplicate_hashes.include? card_hash(card.name, card.desc) }
      duplicate_cards.sort_by {|card| card_hash(card.name, card.desc)}
    end

    def add_logger(logger)
      @logger ||= logger
    end

    def add_label_colors(label_colors)
      @label_colors ||= label_colors
    end

    def add_pivotal_owner_to_trello_member_map(o2m_map)
      @owner_to_member = o2m_map
    end

    def get_board_name
      @board.name
    end

    def get_board_url
      @board.url
    end

    # Creates a card in the given list if one with the same name doesn't already exist.
    def create_card(list_id, pivotal_story, pos)
      card   = @cards[card_hash(pivotal_story.name, pivotal_story.description)]
      card ||= begin
        @logger.puts "Creating a card for #{pivotal_story.story_type} '#{pivotal_story.name}'."
        retry_with_exponential_backoff( Proc.new {
          Trello::Card.create(
            name:    pivotal_story.name,
            desc:    pivotal_story.description,
            list_id: list_id,
            pos:     pos,
          )
        })
      end

      ensure_list_is_correct(card,list_id)
      ensure_position_is_correct(card, pos)
      create_comments(card, pivotal_story)
      create_tasks(card, pivotal_story)
      ensure_card_members_are_correct(card, pivotal_story)
      create_story_labels(card, pivotal_story)
      create_points_labels(card, pivotal_story)

      key                  = card_hash(card.name, card.desc)
      @cards[key]          = card

      @touched_cards     ||= []
      @touched_cards.push(card.id)

      card
    end

    # Returns a hash of available boards, keyed on board ID.
    def board_choices
      Trello::Board.all.each_with_object({}) do |board, hash|
        hash[board.id] = board.name
      end
    end

    # Returns a hash of available lists for the given board, keyed on board ID.
    def list_choices
      choices = @lists.each_with_object({}) do |list, hash|
        hash[list.id] = list.name
      end
      choices = Hash[choices.sort_by { |_, v| v }]
      choices[false] = "[don't import these stories]"
      choices
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

    def delete_all_cards
      delete_cards(@cards.values)
    end

    def delete_cards(cards)
      progress_bar = ProgressBar.new(cards.length)
      cards.each do |card|
        progress_bar.puts "Deleting: #{card.name}"
        delete_card(card)
        progress_bar.increment!
      end
    end

    def delete_card(card)
      retry_with_exponential_backoff( Proc.new { card.delete })
    end

    def delete_all_lists
      @lists.each do |list|
        retry_with_exponential_backoff( Proc.new { list.delete })
      end
    end

    def get_cards_untouched_this_run
      @cards.values.filter { |card| @touched_cards.exclude?(card.id) }
    end

    def pretty_print_cards(cards)
      cards.each {|card| pretty_print_card(card) }
    end

    def pretty_print_card(card)
      puts <<-MULTILINE
      Name:        #{card.name}
      Description: #{card.desc}
      List:        #{card.list.name}
      URL:         #{card.url}

      MULTILINE
    end

    def get_board_members
      retry_with_exponential_backoff( Proc.new { @board.members })
    end

    private

    # Copies notes from the pivotal story to the card.
    def create_comments(card, pivotal_story)
      @logger.puts "Creating comments for card: '#{card.name}'"
      if card.respond_to?(:comments)
        existing_comments = card.comments.map { |c| c.text}
      end
      story_comments = retry_with_exponential_backoff( Proc.new { pivotal_story.comments })
      story_comments.each do |comment|
        next if comment.text.to_s.strip.empty?
        candidate_comment = comment.text.to_s.strip.to_s
        next if existing_comments && existing_comments.include?(candidate_comment)
        retry_with_exponential_backoff( Proc.new {card.add_comment(candidate_comment) })
      end
    end

    # Copies notes from the pivotal story to the card.
    def create_tasks(card, pivotal_story)
      @logger.puts "Creating tasks for card: '#{card.name}'"
      tasks = retry_with_exponential_backoff( Proc.new { pivotal_story.tasks })
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

    def ensure_card_members_are_correct(card, pivotal_story)
      @logger.puts "Adding members to card: '#{card.name}'"
      return unless pivotal_story.respond_to?(:owners)

      if card.respond_to?(:members)
        card_members = retry_with_exponential_backoff( Proc.new { card.members })
        current_card_member_ids = card_members.nil? ? [] : card.members.map { |member| member.id}
      else
        current_card_member_ids = []
      end

      pivotal_owners = retry_with_exponential_backoff( Proc.new { pivotal_story.owners })
      expected_card_member_ids = pivotal_owners.map {|owner| @owner_to_member[owner.id] }.reject(&:nil?)

      card_members_that_do_not_belong = current_card_member_ids - expected_card_member_ids
      card_members_that_are_missing   = expected_card_member_ids - current_card_member_ids

      card_members_that_do_not_belong.each do |id|
        remove_member(card, id)
      end

      card_members_that_are_missing.each do |id|
        add_member(card, id)
      end
    end

    def add_member(card, member_id)
      member = retry_with_exponential_backoff( Proc.new { Trello::Member.find(member_id) })
      @logger.puts "Adding #{member.full_name} to card '#{card.name}'"
      retry_with_exponential_backoff( Proc.new { card.add_member(member) })
    end

    def remove_member(card, member_id)
      member = retry_with_exponential_backoff( Proc.new { Trello::Member.find(member_id) })
      @logger.puts "Removing #{member.full_name} from card '#{card.name}'"
      retry_with_exponential_backoff( Proc.new { card.remove_member(member) })
    end

    def ensure_list_is_correct(card,list_id)
      if card.list_id != list_id
        @logger.puts "Moving '#{card.name}' from #{card.list.name} to #{Trello::List.find(list_id).name}"
        card.move_to_list(list_id)
      end
    end

    def ensure_position_is_correct(card, pos)
      @logger.puts "Checking position of card: '#{card.name}'"
      if card.pos != pos
        @logger.puts "Updating pos from #{card.pos} to #{pos}"
        retry_with_exponential_backoff( Proc.new { card.pos = pos })
      end
    end

    def create_story_labels(card, pivotal_story)
      @logger.puts "Creating labels for card: '#{card.name}'"
      if pivotal_story.labels.is_a? Array
        pivotal_story.labels.each do |label|
          add_label(card, label.name, @label_colors["tracker labels"])
        end
      end
    end

    def create_points_labels(card, pivotal_story)
      @logger.puts "Adding points to card: '#{card.name}'"
      if pivotal_story.respond_to?(:estimate)
        add_label(card, pivotal_story.estimate.to_i.to_s, @label_colors["estimate"])
      end
    end

    # Returns a unique identifier for this list/name/description combination.
    def card_hash(name, description)
      Digest::SHA1.hexdigest("#{name}_#{description}")
    end

    def retry_with_exponential_backoff(function)
      current_retries = 0
      result = nil
      begin
        result = function.call
      rescue StandardError => e
        should_retry, current_retries = should_retry?(current_retries, e)
        retry if should_retry
      rescue RestClient::Exceptions::OpenTimeout => e
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
