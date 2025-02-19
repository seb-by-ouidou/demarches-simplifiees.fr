module Users
  class CommencerController < ApplicationController
    layout 'procedure_context'

    def commencer
      @procedure = retrieve_procedure

      return procedure_not_found if @procedure.blank?

      @revision = params[:test] ? @procedure.draft_revision : @procedure.active_revision

      if params[:prefill_token].present? || commencer_page_is_reloaded?
        retrieve_prefilled_dossier(params[:prefill_token] || session[:prefill_token])
      elsif prefill_params_present?
        build_prefilled_dossier
      end

      if user_signed_in?
        set_prefilled_dossier_ownership if @prefilled_dossier&.orphan?
        check_prefilled_dossier_ownership if @prefilled_dossier
      end

      render 'commencer/show'
    end

    def commencer_test
      redirect_to commencer_path(params[:path], **extra_query_params)
    end

    def dossier_vide_pdf
      @procedure = retrieve_procedure_with_closed
      return procedure_not_found if @procedure.blank? || @procedure.brouillon?

      generate_empty_pdf(@procedure.published_revision)
    end

    def dossier_vide_pdf_test
      @procedure = retrieve_procedure_with_closed
      return procedure_not_found if @procedure.blank?

      generate_empty_pdf(@procedure.draft_revision)
    end

    def sign_in
      @procedure = retrieve_procedure
      return procedure_not_found if @procedure.blank?

      store_user_location!(@procedure)
      redirect_to new_user_session_path
    end

    def sign_up
      @procedure = retrieve_procedure
      return procedure_not_found if @procedure.blank?

      store_user_location!(@procedure)
      redirect_to new_user_registration_path
    end

    def france_connect
      @procedure = retrieve_procedure
      return procedure_not_found if @procedure.blank?

      store_user_location!(@procedure)
      redirect_to france_connect_particulier_path
    end

    def procedure_for_help
      retrieve_procedure
    end

    private

    def extra_query_params
      params.slice(:prefill_token, :test).to_unsafe_h.compact
    end

    def commencer_page_is_reloaded?
      session[:prefill_token].present? && session[:prefill_params_digest] == PrefillParams.digest(params)
    end

    def prefill_params_present?
      params.keys.find { |param| param.split('_').first == "champ" }
    end

    def retrieve_procedure
      Procedure.publiees.or(Procedure.brouillons).find_by(path: params[:path])
    end

    def retrieve_procedure_with_closed
      Procedure.publiees.or(Procedure.brouillons).or(Procedure.closes).order(published_at: :desc).find_by(path: params[:path])
    end

    def build_prefilled_dossier
      @prefilled_dossier = Dossier.new(
        revision: @revision,
        groupe_instructeur: @procedure.defaut_groupe_instructeur_for_new_dossier,
        state: Dossier.states.fetch(:brouillon),
        prefilled: true
      )
      @prefilled_dossier.build_default_individual
      if @prefilled_dossier.save
        @prefilled_dossier.prefill!(PrefillParams.new(@prefilled_dossier, params.to_unsafe_h).to_a)
      end
      session[:prefill_token] = @prefilled_dossier.prefill_token
      session[:prefill_params_digest] = PrefillParams.digest(params)
    end

    def retrieve_prefilled_dossier(prefill_token)
      @prefilled_dossier = Dossier.state_brouillon.prefilled.find_by!(prefill_token: prefill_token)
    end

    # The prefilled dossier is not owned yet, and the user is signed in: they become the new owner
    def set_prefilled_dossier_ownership
      @prefilled_dossier.update!(user: current_user)
      DossierMailer.with(dossier: @prefilled_dossier).notify_new_draft.deliver_later
    end

    # The prefilled dossier is owned by another user: raise an exception
    def check_prefilled_dossier_ownership
      raise ActiveRecord::RecordNotFound unless @prefilled_dossier.owned_by?(current_user)
    end

    def procedure_not_found
      procedure = Procedure.find_by(path: params[:path])

      if procedure&.replaced_by_procedure
        redirect_to commencer_path(procedure.replaced_by_procedure.path, **extra_query_params)
        return
      elsif procedure&.close?
        flash.alert = procedure.service.presence ?
                      t('errors.messages.procedure_archived.with_service_and_phone_email', service_name: procedure.service.nom, service_phone_number: procedure.service.telephone, service_email: procedure.service.email) :
                      t('errors.messages.procedure_archived.with_organisation_only', organisation_name: procedure.organisation)
      else
        flash.alert = t('errors.messages.procedure_not_found')
      end

      redirect_to root_path
    end

    def store_user_location!(procedure)
      store_location_for(:user, commencer_path(procedure.path, **extra_query_params))
    end

    def generate_empty_pdf(revision)
      @dossier = revision.new_dossier
      data = render_to_string(template: 'dossiers/dossier_vide', formats: [:pdf])
      send_data(data, filename: "#{revision.procedure.libelle}.pdf")
    end
  end
end
