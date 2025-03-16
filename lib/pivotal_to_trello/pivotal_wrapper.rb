# frozen_string_literal: true

require 'tracker_api'
require 'progress_bar'

module PivotalToTrello
  # Interface to the Pivotal Tracker API.
  class PivotalWrapper
    # Constructor
    def initialize(token)
      @client = TrackerApi::Client.new(token: token)
    end

    # Returns a hash of available projects keyed on project ID.
    def project_choices
      @client.projects.each_with_object({}) do |project, hash|
        hash[project.id] = project.name
      end
    end

    def add_project(project_id)
      @project_id = project_id
    end

    # Returns all stories for the given project.
    def stories
      @stories = @client.project(@project_id).stories(fields: ':default,before_id,after_id').sort_by(&:id)
      create_story_order_map
      @stories
    end

    def get_story_order_number(story)
      return @pos_map[story.id]
    end

    def get_all_story_owners
      puts "Getting the set of story owners in the pivotal tracker board"
      progress_bar = ProgressBar.new(@stories.length)
      story_owners = @stories.map do |story|
        progress_bar.increment!
        story.owners
      end
      story_owners.flatten.uniq
    end

    # Takes a list of ids and returns an array of PivotalStory objects
    def get_stories_by_ids(story_ids)
      story_ids.map { |id| @client.story(id) }
    end

    # Returns the Pivotal project that we're exporting.
    def project
      @projects             ||= {}
      @projects[project_id] ||= @client.project(@project_id)
    end

    private

    def create_story_order_map
      linking_map = @stories.map { |story| [story.id, story.before_id] }.to_h
      @pos_map = {}
      # find the first story, which is after no other story
      story_id = @stories.find { |story| story.after_id.nil? }.id
      i = 1
      while story_id
        @pos_map[story_id] = i
        i += 1
        story_id = linking_map[story_id]
      end
    end
  end
end
