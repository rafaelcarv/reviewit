require 'tmpdir'
require 'fileutils'
require 'net/http'
require 'openssl'
require 'tempfile'

class MergeRequest < ActiveRecord::Base
  belongs_to :author, class_name: User
  belongs_to :reviewer, class_name: User
  belongs_to :project

  has_many :patches, -> { order(:created_at) }, dependent: :destroy
  has_many :history_events, -> { order(:when) }, dependent: :destroy

  enum status: [:open, :integrating, :needs_rebase, :accepted, :abandoned]

  # Any status >= this is considered a closed MR
  CLOSE_LIMIT = 3

  scope :pending, -> { where("status < #{CLOSE_LIMIT}") }
  scope :closed, -> { where("status >= #{CLOSE_LIMIT}") }

  validates :target_branch, presence: true
  validates :subject, presence: true, length: { maximum: 255 }
  validates :author, presence: true
  validate :author_cant_be_reviewer
  validates :target_branch, format: /\A[\w\d,\.-]+[^.](?<!\.lock)\z/

  before_save :write_history

  after_create :notify_jira
  after_create :send_webpush_creation_notification

  def can_update?
    not %w(accepted integrating).include? status
  end

  def closed?
    MergeRequest.statuses[status] >= CLOSE_LIMIT
  end

  def general_comments?
    Comment.joins(:patch).where(patches: { merge_request_id: id }, comments: { location: 0 }).any?
  end

  def add_patch(diff:, linter_ok:, ci_enabled:, description: '')
    patch = Patch.new
    patch.subject = diff.subject
    patch.commit_message = diff.commit_message
    patch.description = description
    patch.diff = diff.raw
    patch.linter_ok = linter_ok
    patch.gitlab_ci_status = :canceled unless ci_enabled
    patches << patch
    add_history_event(author, 'updated the merge request') if persisted?
  end

  def add_comments(author, patch, comments)
    return if comments.nil?

    count = 0
    transaction do
      comments.each do |location, text|
        next if text.strip.empty?
        comment = Comment.new
        comment.user = author
        comment.patch = patch
        comment.content = text
        comment.location = location
        comment.save!
        count += 1
      end
    end
    return if count.zero?

    add_history_event(author, count == 1 ? 'added a comment.' : "added #{count} comments.")
    send_webpush_comment_notification(author, count)
  end

  def abandon!(reviewer)
    add_history_event reviewer, 'abandoned the merge request'
    self.status = :abandoned
    save!
    patch.remove_ci_branch
  end

  def integrate!(reviewer, patch_id = :not_specified)
    raise 'You tried to accept an outdated version of this merge request.' if patch.id != patch_id &&
                                                                              patch_id != :not_specified
    raise 'This merge request is already closed.' if closed?
    raise 'This merge request is being integrated by another request, please wait' if integrating?

    add_history_event reviewer, 'accepted the merge request'

    self.reviewer = reviewer
    self.status = :integrating
    save!

    patch.push do |success|
      if success
        accepted!
        send_webpush_accept_notification
      else
        add_history_event reviewer, 'failed to integrate merge request'
        needs_rebase!
        send_webpush_needs_rebase_notification
      end
    end
  end

  def patch
    @patch ||= patches.last
  end

  def patch_diff(from = 0, to = nil)
    to ||= patches.count
    raise ActiveRecord::RecordNotFound, 'Patch diff not found' if from >= to
    # convert to zero based index.
    from -= 1
    to -= 1

    return Diff.new(patches[to].diff) if from < 0

    Diff.new(interdiff(patches[from].diff, patches[to].diff), source: :interdiff)
  end

  def deprecated_patches
    patches.where.not(id: patch.id)
  end

  def people_involved
    people = User.joins(:comments)
                 .joins('INNER JOIN patches ON patches.id = comments.patch_id')
                 .joins('INNER JOIN merge_requests ON merge_requests.id = patches.merge_request_id')
                 .where('merge_requests.id = ?', id).uniq
    people << reviewer if reviewer
    (people << author).uniq
  end

  def comments
    Comment.joins(:patch).where('patches.merge_request_id = ?', id)
  end

  class << self
    def waiting_others(mrs, user)
      mrs.select do |mr|
        last_comment = mr.comments.last

        # No coments
        if last_comment.nil? || last_comment.patch_id != mr.patch.id
          mr.author_id == user.id
        # A comment
        else
          last_comment.user_id == user.id
        end
      end
    end
  end

  def my_path
    @my_path ||= Rails.application.routes.url_helpers.project_merge_request_path(project, self)
  end

  private

  def interdiff(diff1, diff2)
    prune_git_headers!(diff1)
    prune_git_headers!(diff2)

    file1 = Tempfile.open('diff1') do |f|
      f.puts(diff1)
      f
    end
    file2 = Tempfile.open('diff2') do |f|
      f.puts(diff2)
      f
    end
    `interdiff #{file1.path} #{file2.path} < /dev/null`.tap do
      file1.unlink
      file2.unlink
    end
  end

  GIT_HEADERS = [/^old mode .+\n/,
                 /^new mode .+\n/,
                 /^deleted file mode .+\n/,
                 /^new file mode .+\n/,
                 /^copy from .+\n/,
                 /^copy to .+\n/,
                 /^rename from .+\n/,
                 /^rename to .+\n/,
                 /^similarity index .+\n/,
                 /^dissimilarity index .+\n/,
                 /^index .+\n/]
  # interdiff has a bug with some git headers in the patch, the bug was already fixed
  # but most distro doesn't have this fix yet.
  # https://github.com/twaugh/patchutils/commit/14261ad5461e6c4b3ffc2f87131601ff79e2a0fc
  def prune_git_headers!(diff)
    GIT_HEADERS.each do |header|
      diff.gsub!(header, '')
    end
    diff
  end

  def write_history
    return if !target_branch_changed? || target_branch_was.nil?
    add_history_event(author, "changed the target branch from #{target_branch_was} to #{target_branch}")
  end

  def add_history_event(who, what)
    history_events << HistoryEvent.new(who: who, what: what)
  end

  def indent_comment(comment)
    comment.each_line.map { |line| "    #{line}" }.join
  end

  def author_cant_be_reviewer
    errors.add(:reviewer, 'can\'t be the author.') if author == reviewer
  end

  def notify_jira
    return if project.jira_username.blank? ||
              project.jira_password.blank? ||
              project.jira_api_url.blank? ||
              project.jira_ticket_regexp.blank?

    match = /#{project.jira_ticket_regexp}/.match(patch.commit_message)
    return if match.nil?

    message = "Merge request created at https://#{ReviewitConfig.mail.domain}/mr/#{id}"
    Thread.new do
      ActiveRecord::Base.connection.close
      match.to_a.each do |ticket_id|
        uri = URI("#{project.jira_api_url}/issue/#{ticket_id}/comment")
        request = Net::HTTP::Post.new(uri.to_s)
        request.basic_auth(project.jira_username, project.jira_password)
        request['Content-Type'] = 'application/json'
        request.body = { 'body' => message }.to_json

        http = Net::HTTP.new(uri.hostname, uri.port)
        http.use_ssl = true if uri.scheme == 'https'
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE if http.use_ssl?
        http.start { |h| h.request(request) }
      end
    end
  end

  def send_webpush_creation_notification
    users = project.users.webpush_enabled.to_a - [author]
    User.send_webpush(users, "MR created on #{project.name}", subject, my_path)
  end

  def send_webpush_accept_notification
    author.send_webpush_assync('Your MR got accepted!', subject, my_path)
  end

  def send_webpush_comment_notification(who, n_of_comments)
    return if who == author
    author.send_webpush_assync("#{n_of_comments} new comments", subject, my_path)
  end

  def send_webpush_needs_rebase_notification
    author.send_webpush_assync('Rebase needed', subject, my_path)
  end
end
