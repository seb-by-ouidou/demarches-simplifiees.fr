# == Schema Information
#
# Table name: dossier_corrections
#
#  id             :bigint           not null, primary key
#  resolved_at    :datetime
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#  commentaire_id :bigint
#  dossier_id     :bigint           not null
#
class DossierCorrection < ApplicationRecord
  belongs_to :dossier
  belongs_to :commentaire

  validates_associated :commentaire

  scope :pending, -> { where(resolved_at: nil) }

  def resolved?
    resolved_at.present?
  end
end
