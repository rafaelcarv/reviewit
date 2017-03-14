class User < ActiveRecord::Base
  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable and :omniauthable
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :trackable, :validatable
  has_and_belongs_to_many :projects

  before_create :generate_api_token
  has_many :comments
  has_many :merge_requests, foreign_key: :author_id

  validates :name, presence: true, allow_blank: false
  validates :api_token, uniqueness: true

  def self.valid_token?(token)
    User.exists?(api_token: token)
  end

  def self.all_names
    User.all.map(&:name)
  end

  def email_address
    "#{name} <#{email}>"
  end

  def send_push_notification(text)
    Webpush.payload_send(
        message: text,
        endpoint: webpush_endpoint,
        p256dh: webpush_p256dh,
        auth: webpush_auth,
        ttl: 24 * 60 * 60,
        vapid: {
          subject: 'mailto:hugo.pl@gmail.com', # This need to be read from reviewit.yml
          public_key: ReviewitConfig.webpush_public_key,
          private_key: ReviewitConfig.webpush_private_key
        }
      )
  end

  private

  def generate_api_token
    loop do
      self.api_token = SecureRandom.urlsafe_base64
      break unless User.exists?(api_token: api_token)
    end
  end
end
