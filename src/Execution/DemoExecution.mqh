// Optional execution of newly confirmed 1.604 signals. Off by default, DEMO only.
// Never closes/modifies existing positions. SL/TP travel in the initial request.

string g_exec_account="";
long g_exec_login=0;

uint ExecHash(const string value)
  {
   uint hash=2166136261;
   for(int i=0;i<StringLen(value);i++) hash=(hash^(uint)StringGetCharacter(value,i))*16777619;
   return hash;
  }

bool ExecRiskAllowed(const double risk,const double minimum,const double maximum,
                     const double daily_net,const double daily_limit,const bool daily_hit)
  {
   return MathIsValidNumber(risk) && MathIsValidNumber(daily_net) &&
           minimum>=0.0 && maximum>0.0 && maximum<=2.00 && maximum>=minimum &&
          daily_limit>0.0 && daily_limit<=10.0 && !daily_hit &&
          risk>=minimum-1e-8 && risk<=maximum+1e-8 &&
          MathMax(0.0,-daily_net)+risk<=daily_limit+1e-8;
  }

bool ExecFresh(const long now_msc,const long quote_msc,const datetime signal_bar)
  {
   long closed=(long)(signal_bar+60)*1000;
   return signal_bar>0 && quote_msc>=closed && quote_msc<closed+60000 &&
          now_msc>=quote_msc && now_msc-quote_msc<=5000;
  }

double ExecGridPrice(const double price,const double step,const int digits,const bool up)
  {
   if(step<=0.0 || price<=0.0) return 0.0;
   double units=price/step;
   return NormalizeDouble((up ? MathCeil(units-1e-8) : MathFloor(units+1e-8))*step,digits);
  }

bool ExecStopsValid(const bool buy,const double bid,const double ask,const double sl,
                    const double tp,const double minimum)
  {
   return VariantsStopsValid(buy,bid,ask,sl,tp,minimum);
  }

// Only definitive broker rejections release the uncertain-request guard.
bool ExecDefiniteReject(const uint code)
  {
   return code==TRADE_RETCODE_REQUOTE || code==TRADE_RETCODE_REJECT ||
          code==TRADE_RETCODE_CANCEL || code==TRADE_RETCODE_INVALID ||
          code==TRADE_RETCODE_INVALID_VOLUME || code==TRADE_RETCODE_INVALID_PRICE ||
          code==TRADE_RETCODE_INVALID_STOPS || code==TRADE_RETCODE_TRADE_DISABLED ||
          code==TRADE_RETCODE_MARKET_CLOSED || code==TRADE_RETCODE_NO_MONEY ||
          code==TRADE_RETCODE_PRICE_CHANGED || code==TRADE_RETCODE_PRICE_OFF ||
          code==TRADE_RETCODE_INVALID_FILL || code==TRADE_RETCODE_TOO_MANY_REQUESTS ||
          code==TRADE_RETCODE_SERVER_DISABLES_AT || code==TRADE_RETCODE_CLIENT_DISABLES_AT;
  }

bool ExecCheckPassed(const bool checked,const uint code)
  { return checked && (code==0 || code==TRADE_RETCODE_DONE); }

bool ExecLog(const string id,const string state,const string detail,const MqlTradeRequest &req,
             const double risk,const double daily_net,const uint retcode=0,
             const ulong order=0,const ulong deal=0)
  {
   bool variants_saved=VariantsExecLog(id,state,ManualExecDetail(id,detail),req,retcode,order,deal);
   string row[]; ArrayResize(row,18);
   row[0]=TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS); row[1]=id; row[2]=state;
   row[3]=ManualExecDetail(id,detail); row[4]=_Symbol; row[5]=EnumToString(req.type);
   row[6]=DoubleToString(req.volume,8); row[7]=DoubleToString(req.price,_Digits);
   row[8]=DoubleToString(req.sl,_Digits); row[9]=DoubleToString(req.tp,_Digits);
   row[10]=DoubleToString(risk,5); row[11]=DoubleToString(daily_net,5);
   row[12]=IntegerToString(retcode); row[13]=(string)order; row[14]=(string)deal;
   row[15]=(string)VariantsMagic(); row[16]=OBSERVER_BUILD_TAG; row[17]=g_writer_session;
   Print("DEMO_EXEC: ",state," | ",id," | ",detail," | retcode ",retcode);
   bool legacy_saved=AppendDiagnostic(TaggedCsv("BCSO_"+SafeSymbolName()+"_execution_v1604.csv"),
       "time_server;signal_id;state;detail;symbol;side;volume;request_price;sl;tp;risk_usd;daily_net_usd;retcode;order_ticket;deal_ticket;magic;writer_build;writer_session",row);
   return variants_saved && legacy_saved;
  }

bool ExecOwnedDeal(const ulong magic,const long position,const string symbol,const ulong &owned[])
  {
   if(symbol==_Symbol && VariantsOwnMagic(magic,VariantsMagic())) return true;
   for(int i=0;i<ArraySize(owned);i++) if(position>0 && owned[i]==(ulong)position) return true;
   return false;
  }

bool ExecDailyNet(double &net,bool &hit)
  {
   net=0.0; hit=false;
   MqlDateTime clock; TimeToStruct(TimeCurrent(),clock);
   clock.hour=0; clock.min=0; clock.sec=0;
   datetime start=StructToTime(clock);
   if(!HistorySelect(0,TimeCurrent())) return false;
   // Include all deals on EA-origin positions, even when a user closes one manually.
   ulong owned[];
   for(int i=0;i<HistoryDealsTotal();i++)
     {
      ulong ticket=HistoryDealGetTicket(i); if(ticket==0) return false;
       if(HistoryDealGetString(ticket,DEAL_SYMBOL)!=_Symbol ||
          !VariantsOwnMagic((ulong)HistoryDealGetInteger(ticket,DEAL_MAGIC),VariantsMagic()) ||
         HistoryDealGetInteger(ticket,DEAL_ENTRY)!=DEAL_ENTRY_IN) continue;
      long position=HistoryDealGetInteger(ticket,DEAL_POSITION_ID);
      if(position<=0) continue;
      bool known=false;
      for(int j=0;j<ArraySize(owned);j++) if(owned[j]==(ulong)position) { known=true; break; }
      if(!known) { int n=ArraySize(owned); ArrayResize(owned,n+1); owned[n]=(ulong)position; }
     }
   // Manual positions and their commissions do not consume the EA daily budget.
   for(int i=0;i<HistoryDealsTotal();i++)
     {
      ulong ticket=HistoryDealGetTicket(i); if(ticket==0) return false;
       if((datetime)HistoryDealGetInteger(ticket,DEAL_TIME)<start ||
          !ExecOwnedDeal((ulong)HistoryDealGetInteger(ticket,DEAL_MAGIC),
                         HistoryDealGetInteger(ticket,DEAL_POSITION_ID),
                         HistoryDealGetString(ticket,DEAL_SYMBOL),owned)) continue;
      ENUM_DEAL_TYPE type=(ENUM_DEAL_TYPE)HistoryDealGetInteger(ticket,DEAL_TYPE);
      bool cost=(type==DEAL_TYPE_CHARGE || type==DEAL_TYPE_COMMISSION ||
                 type==DEAL_TYPE_COMMISSION_DAILY || type==DEAL_TYPE_COMMISSION_MONTHLY ||
                 type==DEAL_TYPE_COMMISSION_AGENT_DAILY || type==DEAL_TYPE_COMMISSION_AGENT_MONTHLY);
      if(type!=DEAL_TYPE_BUY && type!=DEAL_TYPE_SELL && !cost) continue;
      net+=HistoryDealGetDouble(ticket,DEAL_PROFIT)+HistoryDealGetDouble(ticket,DEAL_SWAP)+
           HistoryDealGetDouble(ticket,DEAL_COMMISSION)+HistoryDealGetDouble(ticket,DEAL_FEE);
      if(net<=-VariantsDailyLimit()) hit=true;
     }
   return MathIsValidNumber(net);
  }

bool ExecInitialize()
  {
   g_exec_login=AccountInfoInteger(ACCOUNT_LOGIN);
   g_exec_account="BCSO_EX_"+(string)g_exec_login+"_"+
                  (string)ExecHash(AccountInfoString(ACCOUNT_SERVER))+"_";
   if(!VariantsInitialize()) return false;
   if(!InpDemoExecution) return true;
   if(AccountInfoInteger(ACCOUNT_TRADE_MODE)!=ACCOUNT_TRADE_MODE_DEMO ||
      AccountInfoString(ACCOUNT_CURRENCY)!="USD" || _Period!=PERIOD_M1 ||
      (_Symbol!="Boom 1000 Index" && _Symbol!="Crash 1000 Index") ||
      !InpUseM5ReactionStrategy || InpShadowLegacyRules || InpRulePack!=RULES_1600 ||
       VariantsMagic()==0 || InpPlanRiskMinUSD<0.0 || InpPlanRiskMaxUSD>2.00 ||
      InpExecMaxDailyLossUSD<=0.0 || InpExecMaxDailyLossUSD>10.0 ||
      InpLossPauseMinutes<1 || InpLossPauseMinutes>1440)
      { Print("DEMO_EXEC: parámetros inválidos; requiere Demo USD, Boom/Crash 1000 M1, estrategia 1.604, riesgo 0-2.00 USD, pérdida diaria 10 USD por símbolo y pausa 1-1440 minutos"); return false; }
   return true;
  }

bool ExecLock(double &token)
  {
   string key=g_exec_account+"mutex";
   if(!GlobalVariableCheck(key) && !GlobalVariableTemp(key)) return false;
   double prior=GlobalVariableGet(key);
   if(prior>(double)TimeLocal()) return false;
   token=(double)TimeLocal()+120.0;
   return GlobalVariableSetOnCondition(key,token,prior);
  }

void ExecUnlock(const double token)
  { GlobalVariableSetOnCondition(g_exec_account+"mutex",0.0,token); }

bool ExecPrepare(const string side,const Zone &zone,const datetime bar,
                 const double planned_sl,const double planned_tp,
                 MqlTradeRequest &req,double &risk,double &net,string &reason,const bool level_early=false)
  {
   bool buy=side=="BUY";
   if(AccountInfoInteger(ACCOUNT_TRADE_MODE)!=ACCOUNT_TRADE_MODE_DEMO ||
      AccountInfoString(ACCOUNT_CURRENCY)!="USD" || AccountInfoInteger(ACCOUNT_LOGIN)!=g_exec_login)
     { reason="CUENTA_NO_DEMO_USD_O_CAMBIO_DE_CUENTA"; return false; }
   if(!((_Symbol=="Boom 1000 Index" && buy) || (_Symbol=="Crash 1000 Index" && side=="SELL")))
     { reason="SIMBOLO_O_DIRECCION_NO_AUTORIZADO"; return false; }
    if(!StrategyM15DirectionAllowed(_Symbol,side,DetectTrend(PERIOD_M15,InpScanBarsM15)))
      { reason="TENDENCIA_M15_NO_ALINEADA"; return false; }
   if(!TerminalInfoInteger(TERMINAL_CONNECTED) || !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) ||
      !MQLInfoInteger(MQL_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) ||
      !AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
     { reason="PERMISOS_TRADING_DESACTIVADOS"; return false; }
   // One operation account-wide. Do not merge into, hedge or alter manual positions.
   if(!VariantsExecGuard(zone,planned_sl,reason)) return false;
   if(GlobalVariableGet(g_exec_account+"pending")>0.0)
     { reason="SOLICITUD_ANTERIOR_SIN_CONFIRMACION_REVISAR_DIARIO"; return false; }
   bool hit=false;
   if(!ExecDailyNet(net,hit)) { reason="HISTORIAL_DIARIO_NO_DISPONIBLE"; return false; }
   if(hit) { reason="LIMITE_DIARIO_ALCANZADO"; return false; }
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick) || !(level_early ? ManualQuoteFresh(tick.time_msc) : ExecFresh((long)TimeCurrent()*1000+999,tick.time_msc,bar)))
     { reason="SENAL_O_COTIZACION_CADUCADA"; return false; }
   double point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   double grid=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(point<=0.0 || grid<=0.0) { reason="ESCALA_SIMBOLO_INVALIDA"; return false; }
   req.action=TRADE_ACTION_DEAL; req.symbol=_Symbol; req.magic=VariantsMagic();
   req.type=buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL; req.price=buy ? tick.ask : tick.bid;
   req.sl=ExecGridPrice(planned_sl,grid,_Digits,!buy);
   req.tp=ExecGridPrice(planned_tp,grid,_Digits,!buy);
   if(InpTpMode==SPIKE_QUANTILE)
     {
      double chosen=0.0,tp_rr=0.0; string tp_reason="";
      if(!PlanTakeProfit((int)InpTpMode,side,req.price,MathMax(point,zone.upper-zone.lower),
                         MathMax(0.0,tick.ask-tick.bid),req.sl,planned_tp,
                         SpikeSizeQuantile(InpTpSpikeQuantile),InpTpFallbackWidths,
                         InpTpMinWidths,InpTpMaxWidths,InpTpMinRR,chosen,tp_rr,tp_reason))
        { reason=tp_reason; return false; }
      if(tp_reason=="TP_RR_INSUFICIENTE") { reason=tp_reason; return false; }
      req.tp=ExecGridPrice(chosen,grid,_Digits,!buy);
     }
   req.deviation=InpExecutionDeviationPoints;
   double stops=(double)MathMax(SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL),SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL))*point;
   if(!ExecStopsValid(buy,tick.bid,tick.ask,req.sl,req.tp,stops))
     { reason="SL_TP_NO_VALIDOS_PARA_BROKER"; return false; }
   double distance=MathMax(0.0,MathMax(zone.lower-req.price,req.price-zone.upper));
   if((!level_early && zone.touches<2) || distance>MathMax(point,zone.upper-zone.lower)*InpMaxSignalGapZoneWidths)
     { reason="PRECIO_LEJOS_DE_ZONA_M5"; return false; }
   long mode=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_MODE);
   long modes=SymbolInfoInteger(_Symbol,SYMBOL_ORDER_MODE);
   if((mode!=SYMBOL_TRADE_MODE_FULL && mode!=(buy ? SYMBOL_TRADE_MODE_LONGONLY : SYMBOL_TRADE_MODE_SHORTONLY)) ||
      (modes&SYMBOL_ORDER_MARKET)==0 || (modes&SYMBOL_ORDER_SL)==0 || (req.tp>0.0 && (modes&SYMBOL_ORDER_TP)==0))
     { reason="BROKER_NO_PERMITE_MERCADO_CON_SL_TP"; return false; }
   long filling=SymbolInfoInteger(_Symbol,SYMBOL_FILLING_MODE);
   long execution=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_EXEMODE);
   if((filling&SYMBOL_FILLING_FOK)!=0 || execution==SYMBOL_TRADE_EXECUTION_INSTANT || execution==SYMBOL_TRADE_EXECUTION_REQUEST)
      req.type_filling=ORDER_FILLING_FOK;
   else if((filling&SYMBOL_FILLING_IOC)!=0) req.type_filling=ORDER_FILLING_IOC;
   else { reason="SIN_FOK_IOC"; return false; }
   // Reserve the requested price deviation before sizing; actual gaps can exceed it.
   double adverse=req.price+(buy ? 1.0 : -1.0)*InpExecutionDeviationPoints*point;
   if(!StrategyRiskVolume(side,adverse,req.sl,req.volume,risk,reason)) return false;
   if(!VariantsCapVolume(side,adverse,req.sl,req.volume,risk,reason)) return false;
   double quoted_profit=0.0;
   if(!OrderCalcProfit(req.type,_Symbol,req.volume,req.price,req.sl,quoted_profit) ||
      -quoted_profit<InpPlanRiskMinUSD-1e-8)
     { reason="RIESGO_COTIZADO_MENOR_AL_MINIMO"; return false; }
   if(!ExecRiskAllowed(risk,InpPlanRiskMinUSD,InpPlanRiskMaxUSD,net-VariantsOpenRisk(_Symbol),VariantsDailyLimit(),hit))
     { reason="RIESGO_O_PRESUPUESTO_DIARIO_INSUFICIENTE"; return false; }
   double gain=buy ? req.tp-adverse : adverse-req.tp;
   if(req.tp>0.0 && (gain<=0.0 || gain/MathAbs(adverse-req.sl)<InpMinimumRewardRisk))
     { reason="OBJETIVO_O_RR_INSUFICIENTE_AL_ENVIAR"; return false; }
   return true;
  }

void DemoExecuteConfirmed(const string id,const string side,const Zone &zone,
                          const datetime bar,const double sl,const double tp,const bool level_early=false)
  {
   if(!InpDemoExecution || !ActivePack() || (level_early && !ManualEarlyEnabled(id))) return;
   MqlTradeRequest req={}; double risk=0.0,net=0.0,token=0.0; string reason="";
   req.type=side=="BUY" ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   string pause_key="BCSO_PAUSE_UNTIL_"+_Symbol;
   if(GlobalVariableCheck(pause_key) && TimeCurrent()<(datetime)GlobalVariableGet(pause_key))
     { ExecLog(id,"DESCARTADA","PAUSA_TRAS_STOPS",req,0.0,0.0); return; }
   if(!ExecLock(token)) { ExecLog(id,"DESCARTADA","OTRA_INSTANCIA_EVALUANDO",req,0.0,0.0); return; }
   if(!ExecPrepare(side,zone,bar,sl,tp,req,risk,net,reason,level_early))
     { ExecLog(id,"DESCARTADA",reason,req,risk,net); ExecUnlock(token); return; }
   string bar_key=g_exec_account+"bar_"+(string)ExecHash(_Symbol);
   if(GlobalVariableGet(bar_key)>=(double)bar)
     { ExecLog(id,"DESCARTADA","VELA_YA_INTENTADA",req,risk,net); ExecUnlock(token); return; }
   req.comment="BCSO|"+(string)ExecHash(id);
   if(level_early && !ManualExecArmRequest(id)) { ExecLog(id,"DESCARTADA","PERSISTENCIA_LEVEL_ID",req,risk,net); ExecUnlock(token); return; }
   if(!VariantsArmZone(zone)) { ExecLog(id,"DESCARTADA","PERSISTENCIA_ENFRIAMIENTO",req,risk,net); ExecUnlock(token); return; }
   MqlTradeCheckResult check={};
   bool checked=OrderCheck(req,check);
   if(!ExecCheckPassed(checked,check.retcode))
     { ExecLog(id,"DESCARTADA","ORDERCHECK: "+check.comment,req,risk,net,check.retcode); ExecUnlock(token); return; }
   // Journal and durable latch BEFORE send. No automatic retries, even on timeout.
   if(!ExecLog(id,"PREPARADA","Orden comprobada; aún no enviada",req,risk,net))
     { ExecUnlock(token); return; }
   if(GlobalVariableSet(bar_key,(double)bar)==0 ||
      GlobalVariableSet(g_exec_account+"pending",(double)ExecHash(id)+1.0)==0)
     { Print("DEMO_EXEC: no se pudo persistir el intento; no enviado"); ExecUnlock(token); return; }
   GlobalVariablesFlush();
   MqlTradeResult result={};
   bool sent=OrderSend(req,result);
   if(ExecDefiniteReject(result.retcode)) GlobalVariableSet(g_exec_account+"pending",0.0);
   GlobalVariablesFlush();
   string state=(sent && (result.retcode==TRADE_RETCODE_DONE || result.retcode==TRADE_RETCODE_DONE_PARTIAL ||
                         result.retcode==TRADE_RETCODE_PLACED)) ? "ACEPTADA_ESPERANDO_DEAL" :
                         (ExecDefiniteReject(result.retcode) ? "RECHAZADA_BROKER" : "ESTADO_INCIERTO_BLOQUEADO");
   ExecLog(id,state,result.comment,req,risk,net,result.retcode,result.order,result.deal);
   ExecUnlock(token);
  }

void ExecTradeTransaction(const MqlTradeTransaction &trans)
  {
   if(!InpDemoExecution || trans.type!=TRADE_TRANSACTION_DEAL_ADD || trans.deal==0 ||
      !HistoryDealSelect(trans.deal) || HistoryDealGetString(trans.deal,DEAL_SYMBOL)!=_Symbol ||
      (ulong)HistoryDealGetInteger(trans.deal,DEAL_MAGIC)!=VariantsMagic()) return;
   ulong order=(ulong)HistoryDealGetInteger(trans.deal,DEAL_ORDER);
   bool entering=HistoryDealGetInteger(trans.deal,DEAL_ENTRY)==DEAL_ENTRY_IN;
   string comment=HistoryDealGetString(trans.deal,DEAL_COMMENT);
   if(HistoryOrderSelect(order)) comment=HistoryOrderGetString(order,ORDER_COMMENT);
   double pending=GlobalVariableGet(g_exec_account+"pending");
   if(entering && VariantsPendingMatches(comment,pending))
     { GlobalVariableSet(g_exec_account+"pending",0.0); GlobalVariablesFlush(); }
   MqlTradeRequest req={}; req.symbol=_Symbol;
   req.type=HistoryDealGetInteger(trans.deal,DEAL_TYPE)==DEAL_TYPE_BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   req.volume=HistoryDealGetDouble(trans.deal,DEAL_VOLUME); req.price=HistoryDealGetDouble(trans.deal,DEAL_PRICE);
   req.sl=HistoryDealGetDouble(trans.deal,DEAL_SL); req.tp=HistoryDealGetDouble(trans.deal,DEAL_TP);
   double profit=0.0,risk=0.0;
   if(entering && req.sl>0.0 && OrderCalcProfit(req.type,_Symbol,req.volume,req.price,req.sl,profit)) risk=MathMax(0.0,-profit);
   double actual_net=HistoryDealGetDouble(trans.deal,DEAL_PROFIT)+HistoryDealGetDouble(trans.deal,DEAL_COMMISSION)+
                     HistoryDealGetDouble(trans.deal,DEAL_SWAP)+HistoryDealGetDouble(trans.deal,DEAL_FEE);
   ExecLog(comment,entering ? "DEAL_ENTRADA_CONFIRMADO" : "DEAL_SALIDA_CONFIRMADO",
           "neto_deal="+DoubleToString(actual_net,5),req,risk,0.0,0,order,trans.deal);
   if(entering && (req.sl<=0.0 || risk>InpPlanRiskMaxUSD+1e-8))
      Alert("DEMO_EXEC: revisar ejecución ",trans.deal," | riesgo al precio ejecutado ",DoubleToString(risk,2)," USD | SL ",req.sl);
  }

void ExecLossPauseDecision(const int previous,const double net,const bool stopped,
                           const datetime now,const int minutes,int &next,datetime &until)
  {
   next=MathMax(0,previous); until=0;
   if(net>=0.0) next=0;
   else if(stopped)
     {
      next++;
      if(next>=2) { next=0; until=now+minutes*60; }
     }
  }

void ExecLossPauseTransaction(const MqlTradeTransaction &trans)
  {
   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD || trans.deal==0 ||
      !HistoryDealSelect(trans.deal) || HistoryDealGetString(trans.deal,DEAL_SYMBOL)!=_Symbol) return;
   long entry=HistoryDealGetInteger(trans.deal,DEAL_ENTRY);
   if(entry!=DEAL_ENTRY_OUT && entry!=DEAL_ENTRY_OUT_BY) return;
   bool stopped=HistoryDealGetInteger(trans.deal,DEAL_REASON)==DEAL_REASON_SL;
   long position=HistoryDealGetInteger(trans.deal,DEAL_POSITION_ID);
   if(position<=0 || !HistorySelectByPosition(position)) return;
   string done_key="BCSO_LOSS_DONE_"+_Symbol;
   if(GlobalVariableCheck(done_key) && GlobalVariableGet(done_key)==(double)position) return;
   double opened=0.0,closed=0.0,net=0.0;
   bool owned=false;
   for(int i=0;i<HistoryDealsTotal();i++)
     {
      ulong deal=HistoryDealGetTicket(i);
      if(deal==0 || HistoryDealGetString(deal,DEAL_SYMBOL)!=_Symbol) continue;
      net+=HistoryDealGetDouble(deal,DEAL_PROFIT)+HistoryDealGetDouble(deal,DEAL_COMMISSION)+
           HistoryDealGetDouble(deal,DEAL_SWAP)+HistoryDealGetDouble(deal,DEAL_FEE);
      ENUM_DEAL_TYPE type=(ENUM_DEAL_TYPE)HistoryDealGetInteger(deal,DEAL_TYPE);
      if(type!=DEAL_TYPE_BUY && type!=DEAL_TYPE_SELL) continue;
      long action=HistoryDealGetInteger(deal,DEAL_ENTRY);
      if(action==DEAL_ENTRY_IN)
        {
         opened+=HistoryDealGetDouble(deal,DEAL_VOLUME);
         if((ulong)HistoryDealGetInteger(deal,DEAL_MAGIC)==VariantsMagic())
           {
            string comment=HistoryDealGetString(deal,DEAL_COMMENT);
            ulong order=(ulong)HistoryDealGetInteger(deal,DEAL_ORDER);
            if(HistoryOrderSelect(order))
              {
               string order_comment=HistoryOrderGetString(order,ORDER_COMMENT);
               if(StringFind(order_comment,"BCSO|")==0) comment=order_comment;
              }
            if(StringFind(comment,"BCSO|")==0) owned=true;
           }
        }
      else if(action==DEAL_ENTRY_OUT || action==DEAL_ENTRY_OUT_BY)
         closed+=HistoryDealGetDouble(deal,DEAL_VOLUME);
     }
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(!owned || opened<=0.0 || closed+MathMax(1e-8,0.5*step)<opened) return;
   string losses_key="BCSO_LOSSES_"+_Symbol;
   string pause_key="BCSO_PAUSE_UNTIL_"+_Symbol;
   int previous=(int)GlobalVariableGet(losses_key),next=previous;
   datetime until=0;
   ExecLossPauseDecision(previous,net,stopped,TimeCurrent(),InpLossPauseMinutes,next,until);
   if(until>0 && GlobalVariableSet(pause_key,(double)until)==0) return;
   if((net>=0.0 || stopped) && GlobalVariableSet(losses_key,(double)next)==0) return;
   if(GlobalVariableSet(done_key,(double)position)==0) return;
   GlobalVariablesFlush();
   if(until>0) Print("DEMO_EXEC: PAUSA_TRAS_STOPS | ",_Symbol," | hasta ",
                     TimeToString(until,TIME_DATE|TIME_SECONDS));
  }
