module DossierCloneConcern
  extend ActiveSupport::Concern

  included do
    belongs_to :parent_dossier, class_name: 'Dossier', optional: true
    has_many :cloned_dossiers, class_name: 'Dossier', foreign_key: :parent_dossier_id, dependent: :nullify, inverse_of: :parent_dossier

    belongs_to :editing_fork_origin, class_name: 'Dossier', optional: true
    has_many :editing_forks, -> { where(hidden_by_reason: nil) }, class_name: 'Dossier', foreign_key: :editing_fork_origin_id, dependent: :destroy, inverse_of: :editing_fork_origin
  end

  def find_or_create_editing_fork(user)
    find_editing_fork(user) || clone(user:, fork: true)
  end

  def find_editing_fork(user, rebase: true)
    fork = editing_forks.find_by(user:)
    fork.rebase! if rebase && fork

    fork
  end

  def owner_editing_fork
    find_or_create_editing_fork(user).tap { DossierPreloader.load_one(_1) }
  end

  def reset_editing_fork!
    if editing_fork? && forked_with_changes?
      destroy_editing_fork!
    end
  end

  def destroy_editing_fork!
    if editing_fork?
      update!(hidden_by_administration_at: Time.current, hidden_by_reason: :stale_fork)
      DestroyRecordLaterJob.perform_later(self)
    end
  end

  def editing_fork?
    editing_fork_origin_id.present?
  end

  def make_diff(editing_fork)
    origin_champs_index = champs_public_all.index_by(&:stable_id_with_row)
    forked_champs_index = editing_fork.champs_public_all.index_by(&:stable_id_with_row)
    updated_champs_index = editing_fork
      .champs_public_all
      .filter { _1.updated_at > editing_fork.created_at }
      .index_by(&:stable_id_with_row)

    added = forked_champs_index.keys - origin_champs_index.keys
    removed = origin_champs_index.keys - forked_champs_index.keys
    updated = updated_champs_index.keys - added

    {
      added: added.map { forked_champs_index[_1] },
      updated: updated.map { forked_champs_index[_1] },
      removed: removed.map { origin_champs_index[_1] }
    }
  end

  def merge_fork(editing_fork)
    return false if invalid? || editing_fork.invalid?
    return false if revision_id > editing_fork.revision_id

    transaction do
      rebase!(force: true)
      diff = make_diff(editing_fork)
      apply_diff(diff)
      touch(:last_champ_updated_at)
      assign_to_groupe_instructeur(editing_fork.groupe_instructeur)
    end
    reload
    update_search_terms_later
    editing_fork.destroy_editing_fork!
  end

  def clone(user: nil, fork: false)
    dossier_attributes = [:autorisation_donnees, :revision_id, :groupe_instructeur_id]
    relationships = [:individual, :etablissement]

    cloned_champs = champs
      .index_by(&:id)
      .transform_values { [_1, _1.clone(fork)] }

    cloned_dossier = deep_clone(only: dossier_attributes, include: relationships) do |original, kopy|
      PiecesJustificativesService.clone_attachments(original, kopy)

      if original.is_a?(Dossier)
        if fork
          kopy.editing_fork_origin = original
        else
          kopy.parent_dossier = original
        end

        kopy.user = user || original.user
        kopy.state = Dossier.states.fetch(:brouillon)

        kopy.champs = cloned_champs.values.map do |(_, champ)|
          champ.dossier = kopy
          champ.parent = cloned_champs[champ.parent_id].second if champ.child?
          champ
        end
      end
    end

    transaction do
      cloned_dossier.save!(validate: !fork)

      if fork
        cloned_dossier.rebase!
      end
    end

    if fork
      cloned_champs.values.each do |(original, champ)|
        champ.update_columns(created_at: original.created_at, updated_at: original.updated_at)
      end
    end

    cloned_dossier.reload
  end

  def forked_with_changes?
    if forked_diff.present?
      forked_diff.values.any?(&:present?) || forked_groupe_instructeur_changed?
    end
  end

  def champ_forked_with_changes?(champ)
    if forked_diff.present?
      forked_diff.values.any? { _1.include?(champ) }
    end
  end

  private

  def forked_diff
    @forked_diff ||= editing_fork? ? editing_fork_origin.make_diff(self) : nil
  end

  def forked_groupe_instructeur_changed?
    editing_fork_origin.groupe_instructeur_id != groupe_instructeur_id
  end

  def apply_diff(diff)
    champs_index = (champs_public_all + diff[:added]).index_by(&:stable_id_with_row)

    diff[:added].each do |champ|
      if champ.child?
        champ.update_columns(dossier_id: id, parent_id: champs_index.fetch(champ.parent.stable_id_with_row).id)
      else
        champ.update_column(:dossier_id, id)
      end
    end

    champs_to_remove = []
    diff[:updated].each do |champ|
      old_champ = champs_index.fetch(champ.stable_id_with_row)
      champs_to_remove << old_champ

      if champ.child?
        # we need to do that in order to avoid a foreign key constraint
        old_champ.update(row_id: nil)
        champ.update_columns(dossier_id: id, parent_id: champs_index.fetch(champ.parent.stable_id_with_row).id)
      else
        champ.update_column(:dossier_id, id)
      end
    end

    champs_to_remove += diff[:removed]
    champs_to_remove
      .filter { !_1.child? || !champs_to_remove.include?(_1.parent) }
      .each(&:destroy!)
  end
end
