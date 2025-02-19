module Administrateurs
  class AdministrateurController < ApplicationController
    before_action :authenticate_administrateur!
    helper_method :administrateur_as_manager?

    def retrieve_procedure
      id = params[:procedure_id] || params[:id]

      @procedure = current_administrateur.procedures.find(id)

      Sentry.configure_scope do |scope|
        scope.set_tags(procedure: @procedure.id)
      end
    rescue ActiveRecord::RecordNotFound
      flash.alert = 'Démarche inexistante'
      redirect_to admin_procedures_path, status: 404
    end

    def reset_procedure
      @procedure.reset!
    end

    def ensure_not_super_admin!
      if administrateur_as_manager?
        redirect_back fallback_location: root_url, alert: "Interdit aux super admins", status: 403
      end
    end

    private

    def administrateur_as_manager?
      id = params[:procedure_id] || params[:id]

      current_administrateur.administrateurs_procedures
        .exists?(procedure_id: id, manager: true)
    end
  end
end
