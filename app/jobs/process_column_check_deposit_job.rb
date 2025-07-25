# frozen_string_literal: true

class ProcessColumnCheckDepositJob < ApplicationJob
  class UnconfidentError < StandardError; end
  class ApiError < StandardError; end

  def perform(check_deposit:, validate: true)
    raise ArgumentError, "check deposit already processed" if check_deposit.column_id.present? || check_deposit.increase_id.present?

    conn = Faraday.new url: "https://api.column.com" do |f|
      f.request :basic_auth, "", Credentials.fetch(:COLUMN, ColumnService::ENVIRONMENT, :API_KEY)
      f.request :multipart
      f.response :raise_error
      f.response :json
    end

    # Upload front
    front = check_deposit.front.open do |file|
      conn.post("/transfers/checks/image/front", { file: Faraday::Multipart::FilePart.new(file.path, check_deposit.front.content_type) }).body
    end

    raise UnconfidentError, "could not confidently parse payment details from check. confidence was #{front["micr_line_confidence"]}" if validate && front["micr_line_confidence"] < 0.8

    # Upload back
    back = check_deposit.back.open do |file|
      conn.post("/transfers/checks/image/back", { file: Faraday::Multipart::FilePart.new(file.path, check_deposit.back.content_type) }).body
    end

    event = check_deposit.event
    account_number_id = (event.column_account_number || event.create_column_account_number)&.column_id

    column_check_deposit = ColumnService.post("/transfers/checks/deposit", bank_account_id: ColumnService::Accounts::FS_MAIN,
                                                                           account_number_id:,
                                                                           deposited_amount: check_deposit.amount_cents,
                                                                           currency_code: "USD",
                                                                           micr_line: front["micr_line"],
                                                                           image_front: front["image_front"],
                                                                           image_back: back["image_back"],
                                                                           idempotency_key: "check_deposit_#{check_deposit.id}")

    check_deposit.update!(column_id: column_check_deposit["id"], status: :submitted)

    check_deposit.broadcast_replace(target: [check_deposit, :status], partial: "check_deposits/status", locals: { check_deposit: })

    check_deposit

  rescue Faraday::Error, ProcessColumnCheckDepositJob::UnconfidentError => e
    check_deposit.update!(status: :manual_submission_required)
    Rails.error.unexpected "Check deposit ##{check_deposit.id} needs to be manually submitted to Column."
    raise ApiError, e.response_body["message"] if e.is_a?(Faraday::Error)
  end

end
