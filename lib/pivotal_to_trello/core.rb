# frozen_string_literal: true

require 'rubygems'
require 'highline/import'

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
      prompt_for_details

      puts "\nBeginning import..."
      stories = pivotal.stories(options.pivotal_project_id)

      if stories.empty?
        return
      end

      linking_map = stories.map { |story| [story.id, story.before_id] }.to_h
      pos_map = {}
      # find the first story, which is after no other story
      story_id = stories.find { |story| story.after_id.nil? }.id
      i = 1
      while story_id
        pos_map[story_id] = i
        i += 1
        story_id = linking_map[story_id]
      end

      stories.each do |story|
        list_id = get_list_id(story, options)
        next unless list_id
        card    = trello.create_card(list_id, story, pos_map[story.id])

        label_color = get_label_color(story, options)
        trello.add_label(card, story.story_type, label_color) unless label_color.nil?
      end
    end

    # Returns the options struct.
    attr_reader :options

    private

    # Returns the Trello list_id to import the given story into, based on the users input.
    def get_list_id(story, options)
      state_list_id_finder = {
        'accepted' => options.accepted_list_id,
        'rejected' => options.rejected_list_id,
        'finished' => options.finished_list_id,
        'delivered' => options.delivered_list_id,
        'started' => options.current_list_id,
        'unscheduled' => options.icebox_list_id,
      }
      state_list_id_finder.default = nil

      type_list_id_finder = {
        'feature' => options.feature_list_id,
        'chore' => options.chore_list_id,
        'bug' => options.bug_list_id,
        'release' => options.release_list_id,
      }

      if story.current_state == 'unstarted'
        list_id = type_list_id_finder[story.story_type]
      else
        list_id = state_list_id_finder[story.current_state]
      end

      if list_id.nil?
        puts "Ignoring story #{story.id} - type is '#{story.story_type}', state is '#{story.current_state}'"
      end

      list_id
    end

    # Returns the Trello label for the given story into, based on the users input.
    def get_label_color(story, options)
      label_color = nil

      if story.story_type == 'bug' && options.bug_label
        label_color = options.bug_label
      elsif story.story_type == 'feature' && options.feature_label
        label_color = options.feature_label
      elsif story.story_type == 'chore' && options.chore_label
        label_color = options.chore_label
      elsif story.story_type == 'release' && options.release_label
        label_color = options.release_label
      end

      label_color
    end

    # Prompts the user for details about the import/export.
    def prompt_for_details
      options.pivotal_project_id = prompt_selection('Which Pivotal project would you like to export?', pivotal.project_choices)
      options.trello_board_id    = prompt_selection('Which Trello board would you like to import into?', trello.board_choices)
      options.icebox_list_id     = prompt_selection("Which Trello list would you like to put 'icebox' stories into?", trello.list_choices(options.trello_board_id))
      options.current_list_id    = prompt_selection("Which Trello list would you like to put 'current' stories into?", trello.list_choices(options.trello_board_id))
      options.finished_list_id   = prompt_selection("Which Trello list would you like to put 'finished' stories into?", trello.list_choices(options.trello_board_id))
      options.delivered_list_id  = prompt_selection("Which Trello list would you like to put 'delivered' stories into?", trello.list_choices(options.trello_board_id))
      options.accepted_list_id   = prompt_selection("Which Trello list would you like to put 'accepted' stories into?", trello.list_choices(options.trello_board_id))
      options.rejected_list_id   = prompt_selection("Which Trello list would you like to put 'rejected' stories into?", trello.list_choices(options.trello_board_id))
      options.bug_list_id        = prompt_selection("Which Trello list would you like to put 'backlog' bugs into?", trello.list_choices(options.trello_board_id))
      options.chore_list_id      = prompt_selection("Which Trello list would you like to put 'backlog' chores into?", trello.list_choices(options.trello_board_id))
      options.feature_list_id    = prompt_selection("Which Trello list would you like to put 'backlog' features into?", trello.list_choices(options.trello_board_id))
      options.release_list_id    = prompt_selection("Which Trello list would you like to put 'backlog' releases into?", trello.list_choices(options.trello_board_id))
      options.bug_label          = prompt_selection('What color would you like to label bugs with?', trello.label_choices)
      options.feature_label      = prompt_selection('What color would you like to label features with?', trello.label_choices)
      options.chore_label        = prompt_selection('What color would you like to label chores with?', trello.label_choices)
      options.release_label      = prompt_selection('What color would you like to label releases with?', trello.label_choices)
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
