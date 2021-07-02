#!/usr/bin/env ruby

##############################################################################
# Script that goes through all merged PRs for a given timeframe and:
#
# - assigns the PR to an assignee
# - adds a label to the PR
#
# The assignee will be set to:
# - The author, if the author is member of specified organisation or is the
#   merger of the PR
# - The merger, if the author is not member of specified organisation
#
# This is free and unencumbered software released into the public domain.
# For more information, please refer to <http://unlicense.org/>
##############################################################################

require 'date'
require 'pp'

# 'gem install octokit' before!
require 'octokit'

if not ENV['GITHUB_TOKEN']
  STDERR.puts("Please set GITHUB_TOKEN environment")
  exit 1
end

if not ENV['GITHUB_REPO']
  STDERR.puts("Please set GITHUB_REPO environment (i.e. yourorg/repo)")
  exit 1
end

TOKEN=ENV['GITHUB_TOKEN']
REPO_NAME=ENV['GITHUB_REPO']
ORGANIZATION="argoproj"

# We do not look at PRs created before this date
OLDEST_PR="2020-06-01"

VERIFY_LABEL="needs-verification"

# Whether dry run is true
DRY_RUN=false

# We only consider PRs with following prefixes
PREFIXES = ["feat", "fix"]

if ARGV.length != 1
    STDERR.puts "Usage: #{$0} <since>"
    exit 1
end

begin
    since = Time.parse(ARGV[0])
rescue StandardError => msg
    STDERR.puts "Invalid time specified: #{msg}"
    exit 1
end

puts "Processing PRs since #{since.to_s}"

def get_pr_merger(client, pr)
    preview = { accept: Octokit::Preview::PREVIEW_TYPES[:project_card_events] }
    events = client.issue_events(REPO_NAME, pr.number, preview)
    events.each do |event|
        if event.event == "merged"
            return event.actor.login
        end
    end
end

def is_user_in_argoorg?(client, username)
    return client.organization_member?(ORGANIZATION, username)
end

def has_label?(labels, label)
    labels.each do |l|
        return true if l.name.to_s == label.to_s
    end
    return false
end

def needs_verification?(pr)
  title = pr.title.downcase
  PREFIXES.each do |prefix|
    if title.start_with?("#{prefix}:")
      return true
    end
  end
  return false
end

# Some caches
user_orgs = {}
pr_authors = {}
assignees = {}

client = Octokit::Client.new(:access_token => TOKEN)

pr_page = 1
prs = client.pull_requests(REPO_NAME, 
    :state => 'closed',
    :base => 'master',
    :page => pr_page,
    :per_page => 100,
)

prs.each do |pr|
    if !pr.merged_at.nil? && pr.merged_at > since && needs_verification?(pr)
        if !user_orgs.has_key?(pr.user.login)
            user_orgs[pr.user.login] = is_user_in_argoorg?(client, pr.user.login)
        end
        if !pr_authors.has_key?(pr.user.login)
            pr_authors[pr.user.login] = 1
        else
            pr_authors[pr.user.login] += 1
        end
        merger = get_pr_merger(client, pr)
        assignee = ""
        if merger != pr.user.login
            if user_orgs[pr.user.login]
                assignee = pr.user.login
                puts "Assign PR #{pr.number} (#{pr.created_at.to_s}/#{pr.merged_at.to_s} '#{pr.title}') to OWNER #{assignee} because they are in #{ORGANIZATION} org"
            else
                assignee = merger
                puts "Assign PR #{pr.number} (#{pr.created_at.to_s}/#{pr.merged_at.to_s} '#{pr.title}') to MERGER #{assignee} because author #{pr.user.login} is not in #{ORGANIZATION} org"
            end
        else
            assignee = pr.user.login
            puts "Assign PR #{pr.number} (#{pr.created_at.to_s}/#{pr.merged_at.to_s} '#{pr.title}') to OWNER #{assignee} because author is merger"
        end
        if assignee != "" && pr.assignees.empty?
            if !DRY_RUN
                begin
                    client.add_assignees(REPO_NAME, pr.number, [assignee])
                rescue StandardError => msg
                    STDERR.puts "Error adding assignee to PR #{pr.number}: #{msg}"
                end
            end
            if assignees.has_key?(assignee)
                assignees[assignee] += 1
            else
                assignees[assignee] = 1
            end
        else
            puts "Skipping assignee for PR #{pr.number}, because it has already been assigned."
        end
        if !has_label?(pr.labels, VERIFY_LABEL)
            if !DRY_RUN
                begin
                    client.add_labels_to_an_issue(REPO_NAME, pr.number, [VERIFY_LABEL])
                rescue StandardError => msg
                    STDERR.puts "Error adding label to PR #{pr.number}: #{msg}"
                end
            end
        else
            puts "Skipping label for PR #{pr.number}, because it is already labeled"
        end
    end
    # Fetch next set of PRs
    if prs.last == pr && pr.created_at > Time.parse(OLDEST_PR)
        pr_page += 1
        prs.concat client.pull_requests(REPO_NAME, :state => 'closed', :base => 'master', :page => pr_page, :per_page => 100)
    end
end

puts "PR authors"
pp pr_authors

puts "Assignees"
pp assignees
