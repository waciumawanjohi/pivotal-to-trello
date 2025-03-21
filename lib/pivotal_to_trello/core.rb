# frozen_string_literal: true

require 'rubygems'
require 'highline/import'
require 'progress_bar'

module PivotalToTrello
  # The core entry point of the gem, which handles the import process.
  class Core
    # Constructor
    def initialize(options = OpenStruct.new)
      @options = options
    end

    # Imports a Pivotal project into Trello.
    def import!
      $stdout.sync = true

      prompt_for_project_and_board

      if options.default
        puts <<~MULTILINE

        Note:
        Default works best in an empty board where the user members have already been added.
        The board #{trello.get_board_name} currently has the following members:
        #{trello.pretty_format_members}

        If this is incorrect or incomplete, exit p2t, fix the members and rerun p2t.

        WARNING!
        Running p2t in default mode will wipe all cards and lists from your board.
        MULTILINE
        if agree(<<~MULTILINE
          Confirm, do you want to:
            - DELETE all cards
            - close all lists
          currently in the '#{trello.get_board_name}' board
          #{trello.get_board_url}?

          Yes, No
          MULTILINE
          )
          trello.delete_all_cards
          trello.close_all_lists
        else
          puts "Rerun when ready for clobbering!"
          return
        end
      end

      prompt_for_details

      check_for_duplicates

      puts "\nBeginning import..."
      puts "Preprocessing tracker stories..."

      stories = pivotal.stories

      if stories.empty?
        puts "Tracker project is empty. Done!"
        return
      end


      pivotal_owners = pivotal.get_all_story_owners
      trello_members = trello.get_board_members
      o2m_map = map_owners_to_members(pivotal_owners, trello_members)
      trello.add_pivotal_owner_to_trello_member_map(o2m_map)

      starting_story_id = options.resume_id ? options.resume_id.to_i : 0
      stories_to_process = stories.filter { |story| starting_story_id < story.id }

      progress_bar = ProgressBar.new(stories_to_process.length)
      trello.add_logger(progress_bar)
      progress_bar.puts "\nSending stories to Trello"

      stories_to_process.each do |story|
        progress_bar.increment!

        progress_bar.puts "Processing: #{story.id}"

        card = trello.create_card(story, pivotal.get_story_order_number(story))
      end
      puts "Import complete"
      handle_untouched_trello_cards
      puts "Done!"
    end

    # Returns the options struct.
    attr_reader :options

    private

    # Prompts the user for target export project and import board
    def prompt_for_project_and_board
      pivotal.add_project(prompt_selection('Which Pivotal project would you like to export?', pivotal.project_choices))
      trello.add_board(prompt_selection('Which Trello board would you like to import into?', trello.board_choices))
    end

    # Prompts the user for details about the import/export.
    def prompt_for_details
      if options.default
        trello.create_opinions
        return
      end

      list_assignment = {}
      list_assignment["icebox"]    = prompt_selection("Which Trello list would you like to put 'icebox' stories into?", trello.list_choices),
      list_assignment["bug"]       = prompt_selection("Which Trello list would you like to put 'backlog' BUGS into?", trello.list_choices),
      list_assignment["chore"]     = prompt_selection("Which Trello list would you like to put 'backlog' CHORES into?", trello.list_choices),
      list_assignment["feature"]   = prompt_selection("Which Trello list would you like to put 'backlog' FEATURES into?", trello.list_choices),
      list_assignment["release"]   = prompt_selection("Which Trello list would you like to put 'backlog' RELEASES into?", trello.list_choices),
      list_assignment["started"]   = prompt_selection("Which Trello list would you like to put 'started' stories into?", trello.list_choices),
      list_assignment["finished"]  = prompt_selection("Which Trello list would you like to put 'finished' stories into?", trello.list_choices),
      list_assignment["delivered"] = prompt_selection("Which Trello list would you like to put 'delivered' stories into?", trello.list_choices),
      list_assignment["accepted"]  = prompt_selection("Which Trello list would you like to put 'accepted' stories into?", trello.list_choices),
      list_assignment["rejected"]  = prompt_selection("Which Trello list would you like to put 'rejected' stories into?", trello.list_choices),

      colors = {}
      colors["bug"]                = prompt_selection('What color would you like to label bugs with?', trello.label_choices)
      colors["feature"]            = prompt_selection('What color would you like to label features with?', trello.label_choices)
      colors["chore"]              = prompt_selection('What color would you like to label chores with?', trello.label_choices)
      colors["release"]            = prompt_selection('What color would you like to label releases with?', trello.label_choices)
      colors["tracker labels"]     = prompt_selection('What color would you like to for copies of tracker labels?', trello.label_choices)
      colors["estimate"]           = prompt_selection('What color would you like to for point estimate labels?', trello.label_choices)
      trello.add_list_assignment(list_assignment)
      trello.add_label_colors(colors)
    end

    # Prompts the user to select an option from the given list of choices.
    def prompt_selection(question, choices)
      say("\n#{question}")
      choose do |menu|
        menu.prompt = 'Please select an option : '

        choices.each do |key, value|
          menu.choice value do
            return key
          end
        end
      end
    end

    def handle_untouched_trello_cards
      cards = trello.get_cards_untouched_this_run
      return if cards.length == 0

      puts "Found #{cards.length} cards in trello that did not match any story imported from pivotal tracker."

      question = "What would you like to do with these unimported cards?"
      choices = {
        method(:delete_after_confirmation)         => "Delete, remove all trello cards that were not just imported from tracker",
        method(:review_each_card)                  => "Review, decide for each card whether to keep or delete",
        lambda { |_| puts "Ignoring extra cards"}  => "Nothing, keep all of these cards",
      }

      prompt_selection(question, choices).call(cards)
    end

    def delete_after_confirmation(cards)
      if agree("Confirm: Do you want to delete all cards not just imported?")
        trello.delete_cards(cards)
      end
    end

    def review_each_card(cards)
      puts "Reviewing cards:"
      cards.each do |card|
        puts "\nCard name and url:"
        puts "\t#{card.name}"
        puts "\t#{card.url}"

        choose do |menu|
          menu.prompt = "What should be done with this card?"

          menu.choice :Keep do puts "Keeping" end
          menu.choice :Delete do
            puts "Deleting"
            trello.delete_card(card)
          end
          menu.choice :Quit do return end
        end
      end
    end

    def check_for_duplicates
      duplicates = trello.get_duplicate_trello_cards
      return if duplicates.empty?

      puts "Found duplicates:"
      trello.pretty_print_cards(duplicates)

      puts <<-MULTILINE
      The above cards don't have distinct name and descriptions.
      It's recommended to stop the importer, make their names distinct and then rerun the importer.
      MULTILINE

      choose do |menu|
        menu.prompt = "What would you like to do?"

        menu.choice :Continue
        menu.choice :Quit do exit end
      end
    end

    def map_owners_to_members(pivotal_owners, trello_members)
      puts "Set which Pivotal Tracker users match with which Trello users"
      o2m_map = {}

      members_choices = trello_members.to_h do |member|
        [member.id, trello.pretty_format_member(member)]
      end
      members_choices[nil] = "\nNone of these\n"

      pivotal_owners.each do |owner|
        puts <<~MULTILINE

        Pivotal User
        Name:     #{owner.name}
        Username: #{owner.username}
        Email:    #{owner.email}
        MULTILINE

        o2m_map[owner.id] = prompt_selection("Which Trello user matches the tracker user above?", members_choices)
      end
      o2m_map
    end

    # Returns an instance of the pivotal wrapper.
    def pivotal
      @pivotal ||= PivotalToTrello::PivotalWrapper.new(options.pivotal_token)
    end

    # Returns an instance of the trello wrapper.
    def trello
      @trello ||= PivotalToTrello::TrelloWrapper.new(options.trello_key, options.trello_token)
    end
  end
end
