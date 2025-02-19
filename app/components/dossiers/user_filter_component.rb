class Dossiers::UserFilterComponent < ApplicationComponent
  include DossierHelper

  def initialize(statut:, filter:)
    @statut = statut
    @filter = filter
  end

  attr_reader :statut, :filter

  def render?
    ['en-cours', 'traites'].include?(@statut)
  end

  def states_collection(statut)
    case statut
    when 'en-cours'
      (Dossier.states.values - Dossier::TERMINE) << Dossier::A_CORRIGER
    when 'traites'
      Dossier::TERMINE
    end.map { |state| [t("activerecord.attributes.dossier/state.#{state}"), state] }
  end
end
