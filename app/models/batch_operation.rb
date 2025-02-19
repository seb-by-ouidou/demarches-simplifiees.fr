# == Schema Information
#
# Table name: batch_operations
#
#  id                  :bigint           not null, primary key
#  failed_dossier_ids  :bigint           default([]), not null, is an Array
#  finished_at         :datetime
#  operation           :string           not null
#  payload             :jsonb            not null
#  run_at              :datetime
#  seen_at             :datetime
#  success_dossier_ids :bigint           default([]), not null, is an Array
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  instructeur_id      :bigint           not null
#

class BatchOperation < ApplicationRecord
  enum operation: {
    accepter: 'accepter',
    archiver: 'archiver',
    follow: 'follow',
    passer_en_instruction: 'passer_en_instruction',
    repasser_en_construction: 'repasser_en_construction',
    unfollow: 'unfollow'
  }

  has_many :dossiers, dependent: :nullify
  has_many :dossier_operations, class_name: 'DossierBatchOperation', dependent: :destroy
  has_many :groupe_instructeurs, through: :dossier_operations
  belongs_to :instructeur

  store_accessor :payload, :motivation, :justificatif_motivation

  validates :operation, presence: true

  before_create :build_operations

  RETENTION_DURATION = 4.hours
  MAX_DUREE_GENERATION = 24.hours

  scope :stale, lambda {
    where.not(finished_at: nil)
      .where('updated_at < ?', (Time.zone.now - RETENTION_DURATION))
  }

  scope :stuck, lambda {
    where(finished_at: nil)
      .where('updated_at < ?', (Time.zone.now - MAX_DUREE_GENERATION))
  }

  def dossiers_safe_scope(dossier_ids = self.dossier_ids)
    query = instructeur
      .dossiers
      .visible_by_administration
      .where(id: dossier_ids)
    case operation
    when BatchOperation.operations.fetch(:archiver) then
      query.not_archived.state_termine
    when BatchOperation.operations.fetch(:passer_en_instruction) then
      query.state_en_construction
    when BatchOperation.operations.fetch(:accepter) then
      query.state_en_instruction
    when BatchOperation.operations.fetch(:follow) then
      query.without_followers.en_cours
    when BatchOperation.operations.fetch(:repasser_en_construction) then
      query.state_en_instruction
    when BatchOperation.operations.fetch(:unfollow) then
      query.with_followers.en_cours
    end
  end

  def enqueue_all
    dossiers_safe_scope # later in batch .
      .map { |dossier| BatchOperationProcessOneJob.perform_later(self, dossier) }
  end

  def process_one(dossier)
    case operation
    when BatchOperation.operations.fetch(:archiver)
      dossier.archiver!(instructeur)
    when BatchOperation.operations.fetch(:passer_en_instruction)
      dossier.passer_en_instruction(instructeur: instructeur)
    when BatchOperation.operations.fetch(:accepter)
      dossier.accepter(instructeur: instructeur, motivation: motivation, justificatif: justificatif_motivation)
    when BatchOperation.operations.fetch(:follow)
      instructeur.follow(dossier)
    when BatchOperation.operations.fetch(:repasser_en_construction)
      dossier.repasser_en_construction!(instructeur: instructeur)
    when BatchOperation.operations.fetch(:unfollow)
      instructeur.unfollow(dossier)
    end
  end

  def track_processed_dossier(success, dossier)
    dossiers.delete(dossier)
    touch(:run_at) if called_for_first_time?
    touch(:finished_at)

    if success
      dossier_operation(dossier).done!
    else
      dossier_operation(dossier).fail!
    end
  end

  # when an instructeur want to create a batch from his interface,
  #   another one might have run something on one of the dossier
  #   we use this approach to create a batch with given dossiers safely
  def self.safe_create!(params)
    transaction do
      instance = new(params)
      instance.dossiers = instance.dossiers_safe_scope(params[:dossier_ids])
        .not_having_batch_operation
      if instance.dossiers.present?
        instance.save!
        BatchOperationEnqueueAllJob.perform_later(instance)
        instance
      end
    end
  end

  def called_for_first_time?
    run_at.nil?
  end

  def total_count
    dossier_operations.size
  end

  def success_count
    dossier_operations.success.size
  end

  def errors?
    dossier_operations.error.present?
  end

  def finished_at
    dossiers.empty? ? super : nil
  end

  private

  def dossier_operation(dossier)
    dossier_operations.find_by!(dossier:)
  end

  def build_operations
    dossier_operations.build(dossiers.map { { dossier: _1 } })
  end
end
