module DossierCorrectableConcern
  extend ActiveSupport::Concern

  included do
    A_CORRIGER = 'a_corriger'
    has_many :corrections, class_name: 'DossierCorrection', dependent: :destroy

    scope :with_pending_corrections, -> { joins(:corrections).where(corrections: { resolved_at: nil }) }

    def flag_as_pending_correction!(commentaire)
      return unless may_flag_as_pending_correction?

      corrections.create!(commentaire:)

      return if en_construction?

      repasser_en_construction!(instructeur: commentaire.instructeur)
    end

    def may_flag_as_pending_correction?
      return false if corrections.pending.exists?

      en_construction? || may_repasser_en_construction?
    end

    def pending_correction?
      # We don't want to show any alert if user is not allowed to modify the dossier
      return false unless en_construction?

      corrections.pending.exists?
    end

    def pending_correction
      corrections.pending.first
    end

    def resolve_pending_correction!
      corrections.pending.update!(resolved_at: Time.current)
    end
  end
end
