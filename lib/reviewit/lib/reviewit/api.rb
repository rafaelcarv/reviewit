require 'net/http'
require 'json'

module Reviewit
  class Api
    def initialize base_url, project_id, api_token
      @base_url = base_url
      @project_id = project_id
      @api_token = api_token
    end

    def update_merge_request id, subject, commit_message, diff, description, target_branch
      patch("merge_requests/#{id}", subject: subject, commit_message: commit_message, diff: diff, description: description, target_branch: target_branch)
      mr_url(id)
    end

    def create_merge_request subject, commit_message, diff, target_branch
      res = post('merge_requests', subject: subject, commit_message: commit_message, diff: diff, target_branch: target_branch)
      { url: mr_url(res['mr_id']), id: res['mr_id'] }
    end

    def abandon_merge_request id
      delete("merge_requests/#{id}")
    end

    def pending_merge_requests
      list = get 'merge_requests'
      list.map do |item|
        {
         id:      item['id'],
         url:     mr_url(item['id']),
         status:  item['status'],
         subject: item['subject']
        }
      end
    end

    def merge_request id
      get "merge_requests/#{id}"
    end

    def show_git_patch id
      get "merge_requests/#{id}/show_git_patch"
    end

    def mr_url id
      @base_url.gsub(/api\/?\z/, "mr/#{id}")
    end

  private

    def url_for path
      "#{@base_url}/projects/#{@project_id}/#{path}"
    end

    def full_uri_for path
      # FIXME: Remove API Token from GET requests
      URI("#{url_for(path)}?api_token=#{@api_token}&cli_version=#{VERSION}")
    end

    def post url, args
      send_request url, args
    end

    def patch url, args
      args[:_method] = 'patch'
      send_request url, args
    end

    def delete url
      args = { _method: 'delete' }
      send_request url, args
    end

    def get url
      uri = full_uri_for(url)
      process_response Net::HTTP.get_response(uri)
    end

    def send_request(url, params)
      uri = full_uri_for(url)
      process_response Net::HTTP.post_form(uri, params)
    end

    def process_response response
      data = JSON.load(response.body)
      raise (data['error'] or 'Unknow error') if response.code != '200'
      return data
    rescue JSON::ParserError
      raise 'Error parsing returned JSON.'
    end
  end
end
