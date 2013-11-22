# -*- encoding : utf-8 -*-
class DealsController < ApplicationController
  layout 'main'
  cache_sweeper :export_sweeper, :only => [:destroy, :update, :confirm, :create_general_deal, :create_complex_deal, :create_balance_deal]
  
  menu_group "家計簿"
  menu "仕訳帳"
  before_filter :check_account
  before_filter :find_deal, :only => [:edit, :update, :confirm, :destroy]
  before_filter :find_new_or_existing_deal, :only => [:create_entry]


  RENDER_OPTIONS_PROC = lambda {|deal_type|
    {:partial => "#{deal_type}_form"}
  }

  REDIRECT_OPTIONS_PROC = lambda{|deal|
    {:action => :monthly, :year => deal.date.year.to_s, :month => deal.date.month.to_s, :updated_deal_id => deal.id}
  }
  deal_actions_for :general_deal, :complex_deal, :balance_deal,
    :ajax => true,
    :render_options_proc => RENDER_OPTIONS_PROC,
    :redirect_options_proc => REDIRECT_OPTIONS_PROC

  # 変更フォームを表示するAjaxアクション
  # :pattern_code が指定されていたら画面上はパターン内容をロードする（コードがなければ Code not found）
  # :pattern_id が指定されていたら（TODO: I/F未実装、候補選択でできる予定）それをロードするが、なければもとのまま
  def edit
    load = nil
    if params[:pattern_code].present?
      load =  current_user.deal_patterns.find_by_code(params[:pattern_code])
      # コードが見つからないときはクライアント側で特別に処理するので目印を返す
      unless load
        render :text => 'Code not found'
        return
      end
    elsif params[:pattern_id].present?
      load = current_user.deal_patterns.find_by_id(params[:pattern_id])
    end
    @deal.load(load) if load
    @deal.fill_complex_entries if load || @deal.kind_of?(Deal::General) && (params[:complex] == 'true' || !@deal.simple? || !@deal.summary_unified?)
    render :partial => 'edit'
  end

  # 記入欄を増やすアクション
  # @deal を作り直して書き直す
  def create_entry
    entries_size = params[:deal][:debtor_entries_attributes].size
    @deal.attributes = params[:deal]
    @deal.fill_complex_entries(entries_size+1)
    if @deal.new_record?
      render RENDER_OPTIONS_PROC.call(:complex_deal)
    else
      render :partial => 'edit'
    end
  end

  def update
    @deal.attributes = params[:deal]
    @deal.confirmed = true
    entries_size = params[:deal][:debtor_entries_attributes].try(:size)

    deal_type = @deal.kind_of?(Deal::Balance) ? 'balance_deal' : 'general_deal'
    if @deal.save
      flash[:notice] = "#{@deal.human_name} を更新しました。" # TODO: 他コントーラとDRYに
      flash[:"#{controller_name}_deal_type"] = deal_type
      flash[:day] = @deal.date.day
      render json: {
          id: @deal.id,
          year: @deal.date.year,
          month: @deal.date.month,
          day: @deal.date.day,
          error_view: false
      }
    else
      unless @deal.simple?
        @deal.fill_complex_entries(entries_size)
      end
      render json: {
          id: @deal.id,
          year: @deal.date.year,
          month: @deal.date.month,
          day: @deal.date.day,
          error_view: render_to_string(partial: 'edit_form')
      }
      #render :update do |page|
      #  page[:deal_editor].replace_html :partial => 'edit'
      #end
    end
  end


  # 仕分け帳画面を初期表示するための処理
  # パラメータ：年月、年月日、タブ（明細or残高）、選択行
  def index
    write_target_date if params[:today]
    year, month = read_target_date
    flash.keep
    redirect_to monthly_deals_path(:year => year, :month => month)
  end

  # 月表示
  def monthly
    write_target_date(params[:year], params[:month])
    @year, @month, @day = read_target_date

    @updated_deal = params[:updated_deal_id] ? @user.deals.find(params[:updated_deal_id]) : nil

    @deals_scroll_height = @user.preferences ? @user.preferences.deals_scroll_height : nil

    start_date = Date.new(@year.to_i, @month.to_i, 1)
    end_date = (start_date >> 1) - 1
    @deals = current_user.deals.in_a_time_between(start_date, end_date).all(:include => :readonly_entries,
                  :order => "date, daily_seq")

    # 登録用
    if @updated_deal && @updated_deal.kind_of?(Deal::Balance)
      @deal = Deal::Balance.new
      @deal.account_id = @updated_deal.account_id
      flash.now[:"#{controller_name}_deal_type"] = 'balance_deal'
    else
      @deal = Deal::General.new
      @deal.build_simple_entries
    end
  end

  # 記入の削除
  def destroy
    @deal.destroy
    flash[:notice] = "#{@deal.human_name} を削除しました。"
    write_target_date(@deal.date)
    if request.mobile?
      redirect_to daily_created_mobile_deals_path(:year => @deal.date.year, :month => @deal.date.month, :day => @deal.date.day)
    else
      redirect_to monthly_deals_path(:year => @deal.date.year, :month => @deal.date.month)
    end
  end

  # キーワードで検索したときに一覧を出す
  def search
    raise InvalidParameterError if params[:keyword].blank?
    @keywords = params[:keyword].split(' ')
    @deals = current_user.deals.time_ordering.including(@keywords)
    @as_action = :index
  end

  
  # 確認処理
  def confirm
    @deal.confirm!
    write_target_date(@deal.date)
    redirect_to REDIRECT_OPTIONS_PROC.call(@deal)
  end

  private

  def find_deal
    @deal = current_user.deals.find(params[:id])
  end

  def find_new_or_existing_deal
    if params[:id] == 'new'
      @deal = Deal::General.new
    else
      find_deal
    end
  end

end