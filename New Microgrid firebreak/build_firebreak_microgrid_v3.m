%% =========================================================
%% FIREBREAK ENERGY SYSTEMS — Islanding Microgrid Simulation
%% Average-value model using standard Simulink blocks only
%% Team 10 | Don Weerakoon (14517243) | Professional Studio B
%%
%% Loads:   Fire Station | Water Pumping | Health Clinic | Telecom Tower
%% Solar:   30 kWp  |  Battery: 80 kWh  |  Grid: 415V 50Hz
%% Timeline: Grid fails 17:00 → Island overnight → Resync next day
%% Standards: AS/NZS 4777.2, AS 3000, AS 2067
%% =========================================================

modelName = 'firebreak_microgrid';
savePath  = 'C:\Users\bawan\Documents\MATLAB\firebreak_microgrid.slx';

%% === Parameters (match shared parameter file) ==================
P.Vnom      = 415;          % Nominal line voltage (V)
P.fnom      = 50;           % Nominal frequency (Hz)
P.PV_kWp    = 30;           % Solar array size (kWp)
P.Bat_kWh   = 80;           % Battery capacity (kWh)
P.Bat_init  = 1.0;          % Initial SOC (1.0 = 100%)
P.Bat_min   = 0.20;         % Min SOC (20%)
P.Bat_SOC_end = 0.32;       % Target end SOC (32% margin)

% Tier 1 loads (run 24h — battery sized against these)
% Source: proposal + roadshow. Telecom = 58% of Tier 1 energy.
P.P_telecom  = 47.56;       % kW  (58% of 82 kWh/day ÷ 24h)
P.P_health   = 10.0;        % kW  Health clinic
P.P_firestn  = 8.5;         % kW  Fire station
P.P_water    = 16.0;        % kW  Water pumping station
P.P_total    = P.P_telecom + P.P_health + P.P_firestn + P.P_water;
% ≈ 82.06 kW → 82 kWh/day Tier 1 energy (matches roadshow)

% Simulation timeline (seconds)
P.t_end      = 86400;       % 24 hours
P.t_gridfail = 61200;       % 17:00 — grid fails
P.t_nosolar  = 68400;       % 19:00 — solar → 0
P.t_sunrise  = 21600;       % 06:00 next cycle (relative start)
P.t_fullsun  = 50400;       % 14:00 — peak solar

% AS/NZS 4777.2 protection thresholds
P.UV_pu      = 0.85;        % Under-voltage threshold (pu)
P.OV_pu      = 1.10;        % Over-voltage threshold (pu)
P.UF_Hz      = 49.0;        % Under-frequency (Hz)
P.OF_Hz      = 51.0;        % Over-frequency (Hz)
P.ROCOF_lim  = 1.0;         % ROCOF limit (Hz/s)
P.trip_delay = 0.2;         % Trip delay (s)
P.resync_dV  = 0.05;        % Resync ΔV limit (pu)
P.resync_df  = 0.1;         % Resync Δf limit (Hz)
P.resync_dph = 10;          % Resync Δθ limit (degrees)

%% === Housekeeping =============================================
if bdIsLoaded(modelName), close_system(modelName,0); end
new_system(modelName);
open_system(modelName);

set_param(modelName, ...
    'StopTime',    num2str(P.t_end), ...
    'Solver',      'ode45', ...
    'MaxStep',     '0.1', ...
    'RelTol',      '1e-3');

%% Helper: shorthand for add_block
AB = @(src,dst,varargin) add_block(src,[modelName '/' dst],varargin{:});
AL = @(s,d) add_line(modelName,s,d,'autorouting','on');

%% =========================================================
%% SECTION 1 — GRID MODEL (average-value voltage source)
%% Output: V_grid (pu), f_grid (Hz)
%% =========================================================
% Grid voltage in pu — constant 1.0 while healthy
AB('simulink/Sources/Step', 'Grid_Voltage_pu', ...
    'Position',[50,50,100,80]);
set_param([modelName '/Grid_Voltage_pu'], ...
    'Time',       num2str(P.t_gridfail), ...
    'Before',     '1.0', ...
    'After',      '0.0');   % Grid collapses at t_gridfail

% Grid frequency (Hz) — 50 Hz while healthy, 0 when gone
AB('simulink/Sources/Step', 'Grid_Freq_Hz', ...
    'Position',[50,110,100,140]);
set_param([modelName '/Grid_Freq_Hz'], ...
    'Time',    num2str(P.t_gridfail), ...
    'Before',  '50', ...
    'After',   '0');

% Scale voltage to actual V (415 V)
AB('simulink/Math Operations/Gain', 'V_grid_V', ...
    'Position',[150,50,210,80]);
set_param([modelName '/V_grid_V'],'Gain',num2str(P.Vnom));
AL('Grid_Voltage_pu/1','V_grid_V/1');


%% =========================================================
%% SECTION 2 — SOLAR PV MODEL (30 kWp average-value)
%% Uses a piecewise irradiance profile over 24 hours
%% Output: P_solar_kW
%% =========================================================
% Irradiance profile: sunrise 06:00, peak 14:00, set 19:00
% Represented as a lookup table (time → kW output)
timeVec = [0,     21600, 25200, 36000, 50400, 61200, 68400, 86400];
pvVec   = [0,     0,     5,     20,    30,    18,    0,     0    ]; % kW

AB('simulink/Sources/From Workspace', 'Solar_PV_Profile', ...
    'Position',[50,200,150,230]);
% Store as timeseries in base workspace
assignin('base','pv_data', ...
    timeseries(pvVec', timeVec'));
set_param([modelName '/Solar_PV_Profile'], ...
    'VariableName', 'pv_data', ...
    'OutputAfterFinalValue', 'Holding final value');

% PV output in kW
AB('simulink/Signal Routing/Mux','PV_out_label',...
    'Position',[200,200,220,230]);   % placeholder label


%% =========================================================
%% SECTION 3 — BATTERY MODEL (80 kWh, SOC integrator)
%% Inputs : P_charge (kW, +ve = charging, -ve = discharging)
%% Outputs: SOC (0–1), P_battery_kW
%% =========================================================
AB('simulink/Ports & Subsystems/Subsystem','Battery_Model',...
    'Position',[300,180,440,280]);

bSys = [modelName '/Battery_Model'];
Simulink.SubSystem.deleteContents(bSys);

% Input: net power into battery (kW)
add_block('simulink/Sources/In1',[bSys '/P_net_kW'],...
    'Position',[30,80,60,100]);

% Integrate power → energy → SOC
% dSOC/dt = P_net_kW / Bat_kWh  (kW / kWh = 1/h → convert to 1/s: ÷3600)
add_block('simulink/Math Operations/Gain',[bSys '/kWh_to_kWs'],...
    'Position',[90,75,160,105]);
set_param([bSys '/kWh_to_kWs'],'Gain', ...
    ['1/(' num2str(P.Bat_kWh) '*3600)']);

add_block('simulink/Continuous/Integrator',[bSys '/SOC_integrator'],...
    'Position',[200,70,260,110]);
set_param([bSys '/SOC_integrator'],...
    'InitialCondition', num2str(P.Bat_init));

% Clamp SOC between Bat_min and 1.0
add_block('simulink/Math Operations/MinMax',[bSys '/Clamp_max'],...
    'Position',[290,68,350,112]);
set_param([bSys '/Clamp_max'],'Function','min','Inputs','2');
add_block('simulink/Sources/Constant',[bSys '/SOC_max'],...
    'Position',[290,130,330,150]);
set_param([bSys '/SOC_max'],'Value','1.0');

add_block('simulink/Math Operations/MinMax',[bSys '/Clamp_min'],...
    'Position',[380,68,440,112]);
set_param([bSys '/Clamp_min'],'Function','max','Inputs','2');
add_block('simulink/Sources/Constant',[bSys '/SOC_min'],...
    'Position',[380,130,420,150]);
set_param([bSys '/SOC_min'],'Value',num2str(P.Bat_min));

% Output: SOC
add_block('simulink/Sinks/Out1',[bSys '/SOC'],...
    'Position',[490,80,520,100]);
% Output: P_battery (same as input for now — controller sets this)
add_block('simulink/Sinks/Out1',[bSys '/P_bat_kW'],...
    'Position',[490,130,520,150]);

add_line(bSys,'P_net_kW/1','kWh_to_kWs/1');
add_line(bSys,'kWh_to_kWs/1','SOC_integrator/1');
add_line(bSys,'SOC_integrator/1','Clamp_max/1');
add_line(bSys,'SOC_max/1','Clamp_max/2');
add_line(bSys,'Clamp_max/1','Clamp_min/1');
add_line(bSys,'SOC_min/1','Clamp_min/2');
add_line(bSys,'Clamp_min/1','SOC/1');
add_line(bSys,'P_net_kW/1','P_bat_kW/1');


%% =========================================================
%% SECTION 4 — LOAD MODEL (4 Tier-1 critical buildings)
%% Total Tier 1 = 82 kW (matches roadshow)
%% Telecom tower = 58% of energy → highest priority
%% =========================================================
AB('simulink/Ports & Subsystems/Subsystem','Load_Model',...
    'Position',[300,300,440,400]);

lSys = [modelName '/Load_Model'];
Simulink.SubSystem.deleteContents(lSys);

% Input: island_active (1 = islanded, loads shed if SOC low)
add_block('simulink/Sources/In1',[lSys '/island_active'],...
    'Position',[30,80,60,100]);

loadNm = {'Telecom_Tower','Health_Clinic','Fire_Station','Water_Pumping'};
loadkW = [P.P_telecom, P.P_health, P.P_firestn, P.P_water];
totalLoad = sum(loadkW);

for k = 1:4
    yp = 40 + (k-1)*60;
    add_block('simulink/Sources/Constant',[lSys '/' loadNm{k}],...
        'Position',[100,yp,200,yp+30]);
    set_param([lSys '/' loadNm{k}],'Value',num2str(loadkW(k)));
end

% Sum all loads
add_block('simulink/Math Operations/Sum',[lSys '/Total_Load'],...
    'Position',[230,130,280,190]);
set_param([lSys '/Total_Load'],'Inputs','++++');
for k=1:4
    yp = 40+(k-1)*60;
    add_line(lSys,[loadNm{k} '/1'],['Total_Load/' num2str(k)]);
end

add_block('simulink/Sinks/Out1',[lSys '/P_load_kW'],...
    'Position',[320,150,350,170]);
add_line(lSys,'Total_Load/1','P_load_kW/1');

% Also output individual loads for monitoring
add_block('simulink/Sinks/Out1',[lSys '/P_telecom_kW'],...
    'Position',[220,40,250,60]);
add_line(lSys,'Telecom_Tower/1','P_telecom_kW/1');


%% =========================================================
%% SECTION 5 — ISLANDING STATE MACHINE (MATLAB Function)
%% States: 0=GRID_CONNECTED, 1=ISLANDED, 2=RESYNC_CHECK, 3=RECONNECTED
%% Inputs:  V_pu, f_Hz, ROCOF, fire_alarm, V_grid_pu, f_grid_Hz
%% Outputs: pcc_closed (1=closed), island_active, state_id
%% =========================================================
AB('simulink/User-Defined Functions/MATLAB Function', ...
    'Islanding_FSM', 'Position',[500,150,680,350]);

% Write the MATLAB function content
fcnCode = [...
'function [pcc_closed, island_active, state_id] = Islanding_FSM(...\n'...
'    V_pu, f_Hz, ROCOF, fire_alarm, V_grid_pu, f_grid_Hz)\n'...
'%#codegen\n'...
'% Islanding state machine for Firebreak Microgrid\n'...
'% AS/NZS 4777.2 compliant loss-of-supply detection\n'...
'%\n'...
'% States:\n'...
'%   0 = GRID_CONNECTED  — normal, PCC closed\n'...
'%   1 = ISLANDED        — PCC open, battery supplies load\n'...
'%   2 = RESYNC_CHECK    — grid back, checking conditions\n'...
'%   3 = RECONNECTED     — PCC reclosed, back to grid\n'...
'\n'...
'% Thresholds (AS/NZS 4777.2)\n'...
'UV_thresh   = 0.85;   % Under-voltage (pu)\n'...
'OV_thresh   = 1.10;   % Over-voltage (pu)\n'...
'UF_thresh   = 49.0;   % Under-frequency (Hz)\n'...
'OF_thresh   = 51.0;   % Over-frequency (Hz)\n'...
'ROCOF_thresh= 1.0;    % Rate of change of frequency (Hz/s)\n'...
'resync_dV   = 0.05;   % Resync ΔV tolerance (pu)\n'...
'resync_df   = 0.10;   % Resync Δf tolerance (Hz)\n'...
'\n'...
'% Persistent state\n'...
'persistent state;\n'...
'if isempty(state), state = 0; end\n'...
'\n'...
'% Default outputs (required by codegen — overwritten below)\n'...
'pcc_closed    = 1.0;   % PCC closed by default\n'...
'island_active = 0.0;   % not islanded by default\n'...
'state_id      = 0.0;   % GRID_CONNECTED by default\n'...
'\n'...
'% --- Loss of supply detection ---\n'...
'uv_trip    = (V_pu < UV_thresh) || (V_pu > OV_thresh);\n'...
'uf_trip    = (f_Hz < UF_thresh) || (f_Hz > OF_thresh);\n'...
'rocof_trip = (abs(ROCOF) > ROCOF_thresh);\n'...
'fire_trip  = logical(fire_alarm);\n'...
'loss_detected = uv_trip || uf_trip || rocof_trip || fire_trip;\n'...
'\n'...
'% --- Grid returned check ---\n'...
'grid_ok = (V_grid_pu > 0.95) && (V_grid_pu < 1.05) && ...\n'...
'          (f_grid_Hz > 49.5) && (f_grid_Hz < 50.5);\n'...
'\n'...
'% --- Resync conditions (AS/NZS 4777.2 reconnect) ---\n'...
'dV = abs(V_pu - V_grid_pu);\n'...
'df = abs(f_Hz - f_grid_Hz);\n'...
'resync_ok = grid_ok && (dV < resync_dV) && (df < resync_df) && ~fire_trip;\n'...
'\n'...
'% --- State transitions ---\n'...
'switch state\n'...
'    case 0  % GRID_CONNECTED\n'...
'        if loss_detected\n'...
'            state = 1;  % → ISLANDED\n'...
'        end\n'...
'\n'...
'    case 1  % ISLANDED\n'...
'        if grid_ok && ~fire_trip\n'...
'            state = 2;  % → RESYNC_CHECK\n'...
'        end\n'...
'\n'...
'    case 2  % RESYNC_CHECK\n'...
'        if resync_ok\n'...
'            state = 3;  % → RECONNECTED\n'...
'        elseif ~grid_ok || fire_trip\n'...
'            state = 1;  % Back to ISLANDED\n'...
'        end\n'...
'\n'...
'    case 3  % RECONNECTED\n'...
'        if loss_detected\n'...
'            state = 1;  % Trip again if needed\n'...
'        else\n'...
'            state = 0;  % Back to normal\n'...
'        end\n'...
'end\n'...
'\n'...
'% --- Outputs ---\n'...
'pcc_closed    = double(state ~= 1);  % Open only when ISLANDED\n'...
'island_active = double(state == 1 || state == 2);\n'...
'state_id      = double(state);\n'...
];

% Set the MATLAB Function block's script directly via its Stateflow chart object
% NOTE: sprintf(fcnCode) is WRONG here - fcnCode contains literal '%' comment
% characters (e.g. '%#codegen'), which sprintf interprets as format directives
% and silently truncates the script down to just the function signature.
% Use strrep to turn the literal '\n' sequences into real newlines instead.
rt = sfroot;
fsmChart = rt.find('-isa','Stateflow.EMChart','Path',[modelName '/Islanding_FSM']);
fsmChart.Script = strrep(fcnCode, '\n', newline);
disp('  Islanding_FSM script configured (6 inputs, 3 outputs)');


%% =========================================================
%% SECTION 6 — MICROGRID CONTROLLER
%% Decides how much battery power to dispatch
%% Battery fills gap between load and solar (P_bat = P_load - P_solar)
%% =========================================================
AB('simulink/Ports & Subsystems/Subsystem','MG_Controller',...
    'Position',[500,380,680,480]);

cSys = [modelName '/MG_Controller'];
Simulink.SubSystem.deleteContents(cSys);

add_block('simulink/Sources/In1',[cSys '/P_load_kW'], 'Position',[30,60,60,80]);
add_block('simulink/Sources/In1',[cSys '/P_solar_kW'],'Position',[30,110,60,130]);
add_block('simulink/Sources/In1',[cSys '/SOC'],       'Position',[30,160,60,180]);
add_block('simulink/Sources/In1',[cSys '/island_active'],'Position',[30,210,60,230]);

% P_bat = P_load - P_solar  (positive = discharging)
add_block('simulink/Math Operations/Sum',[cSys '/Power_Gap'],...
    'Position',[120,70,170,120]);
set_param([cSys '/Power_Gap'],'Inputs','+-');
add_line(cSys,'P_load_kW/1','Power_Gap/1');
add_line(cSys,'P_solar_kW/1','Power_Gap/2');

% Clamp battery output (can't exceed 100 kW or go below 0 discharge)
add_block('simulink/Math Operations/MinMax',[cSys '/Clamp_bat'],...
    'Position',[210,70,270,110]);
set_param([cSys '/Clamp_bat'],'Function','min','Inputs','2');
add_block('simulink/Sources/Constant',[cSys '/Bat_max_kW'],...
    'Position',[210,130,260,150]);
set_param([cSys '/Bat_max_kW'],'Value','100');  % 100 kW peak inverter
add_line(cSys,'Power_Gap/1','Clamp_bat/1');
add_line(cSys,'Bat_max_kW/1','Clamp_bat/2');

% Only dispatch battery when islanded
add_block('simulink/Math Operations/Product',[cSys '/Island_Gate'],...
    'Position',[310,70,370,120]);
add_line(cSys,'Clamp_bat/1','Island_Gate/1');
add_line(cSys,'island_active/1','Island_Gate/2');

add_block('simulink/Sinks/Out1',[cSys '/P_bat_cmd_kW'],'Position',[420,80,450,100]);
add_line(cSys,'Island_Gate/1','P_bat_cmd_kW/1');


%% =========================================================
%% SECTION 7 — FIRE DETECTION INPUT
%% Set to 1 to simulate fire alarm opening PCC
%% =========================================================
AB('simulink/Sources/Constant','Fire_Alarm',...
    'Position',[50,420,150,450]);
set_param([modelName '/Fire_Alarm'],'Value','0');
% To test fire trip: change Value to '1' or use a Step block


%% =========================================================
%% SECTION 8 — BUS VOLTAGE MODEL (island frequency droop)
%% When islanded, battery inverter controls V and f via droop
%% V_island ≈ 1.0 pu when battery > 20% SOC, droops below
%% f_island ≈ 50 Hz with small droop proportional to load
%% =========================================================
AB('simulink/Ports & Subsystems/Subsystem','Island_VF_Model',...
    'Position',[730,150,890,280]);

vSys = [modelName '/Island_VF_Model'];
Simulink.SubSystem.deleteContents(vSys);

add_block('simulink/Sources/In1',[vSys '/SOC'],       'Position',[30,50,60,70]);
add_block('simulink/Sources/In1',[vSys '/P_load_kW'], 'Position',[30,110,60,130]);
add_block('simulink/Sources/In1',[vSys '/P_bat_kW'],  'Position',[30,170,60,190]);
add_block('simulink/Sources/In1',[vSys '/pcc_closed'],'Position',[30,230,60,250]);

% Voltage: 1.0 pu nominal, droop if SOC < 30%
% V_pu = min(1.0, SOC/0.30) when islanded, else V_grid
add_block('simulink/Math Operations/Gain',[vSys '/V_droop'],...
    'Position',[100,45,160,75]);
set_param([vSys '/V_droop'],'Gain','1/0.30');
add_block('simulink/Math Operations/MinMax',[vSys '/V_clamp'],...
    'Position',[190,45,250,75]);
set_param([vSys '/V_clamp'],'Function','min','Inputs','2');
add_block('simulink/Sources/Constant',[vSys '/V_max'],'Position',[190,90,230,110]);
set_param([vSys '/V_max'],'Value','1.0');

add_line(vSys,'SOC/1','V_droop/1');
add_line(vSys,'V_droop/1','V_clamp/1');
add_line(vSys,'V_max/1','V_clamp/2');

% Frequency: 50 Hz − droop × (P_load − P_bat) / P_rated
% Small droop: 0.004 Hz/kW → at 82kW net = 0.33Hz deviation max
add_block('simulink/Math Operations/Sum',[vSys '/P_imbalance'],...
    'Position',[100,125,150,165]);
set_param([vSys '/P_imbalance'],'Inputs','+-');
add_block('simulink/Math Operations/Gain',[vSys '/f_droop'],...
    'Position',[180,125,240,165]);
set_param([vSys '/f_droop'],'Gain','0.004');   % Hz/kW
add_block('simulink/Math Operations/Sum',[vSys '/f_island'],...
    'Position',[280,125,330,165]);
set_param([vSys '/f_island'],'Inputs','+-');
add_block('simulink/Sources/Constant',[vSys '/f_nom'],'Position',[280,175,320,195]);
set_param([vSys '/f_nom'],'Value','50');

add_line(vSys,'P_load_kW/1','P_imbalance/1');
add_line(vSys,'P_bat_kW/1', 'P_imbalance/2');
add_line(vSys,'P_imbalance/1','f_droop/1');
add_line(vSys,'f_nom/1','f_island/1');
add_line(vSys,'f_droop/1','f_island/2');

% ROCOF = df/dt
add_block('simulink/Continuous/Derivative',[vSys '/ROCOF'],...
    'Position',[370,125,430,165]);
add_line(vSys,'f_island/1','ROCOF/1');

% Outputs
add_block('simulink/Sinks/Out1',[vSys '/V_pu'],   'Position',[320,50,350,70]);
add_block('simulink/Sinks/Out1',[vSys '/f_Hz'],   'Position',[470,130,500,150]);
add_block('simulink/Sinks/Out1',[vSys '/ROCOF_out'],'Position',[470,170,500,190]);
add_line(vSys,'V_clamp/1','V_pu/1');
add_line(vSys,'f_island/1','f_Hz/1');
add_line(vSys,'ROCOF/1','ROCOF_out/1');


%% =========================================================
%% SECTION 9 — WIRE EVERYTHING TOGETHER
%% =========================================================

% Solar profile → MG_Controller and Load_Model
AL('Solar_PV_Profile/1', 'MG_Controller/2');

% Load_Model outputs
AL('Load_Model/1', 'MG_Controller/1');     % P_load → controller
AL('Load_Model/1', 'Island_VF_Model/2');  % P_load → VF model

% Battery_Model → MG_Controller (SOC feedback)
AL('Battery_Model/1', 'MG_Controller/3');  % SOC

% Islanding_FSM → everywhere
% NOTE: Islanding_FSM (island_active) -> MG_Controller (Island_Gate) ->
% Island_VF_Model (f_Hz/ROCOF) -> Islanding_FSM closes an algebraic loop,
% and Islanding_FSM has persistent state, which Simulink disallows inside
% an algebraic loop. Break it with a Memory block (one-step delay) so the
% controller gates on the *previous* step's islanding decision.
AB('simulink/Discrete/Memory', 'Island_Active_Delay', ...
    'Position',[720,420,760,450]);
AL('Islanding_FSM/2', 'Island_Active_Delay/1');       % island_active
AL('Island_Active_Delay/1', 'MG_Controller/4');       % island_active (delayed)
% NOTE: FSM needs V_pu, f_Hz, ROCOF, fire, V_grid, f_grid as inputs
% Wire after opening model — see connection list below

% Island VF model ← island_active, SOC, P_load, P_bat
AL('Battery_Model/1','Island_VF_Model/1');  % SOC
AL('MG_Controller/1','Island_VF_Model/3'); % P_bat_cmd
AL('Islanding_FSM/1','Island_VF_Model/4'); % pcc_closed

% Fire alarm → FSM
AL('Fire_Alarm/1','Islanding_FSM/4');

% Grid signals → FSM
AL('Grid_Voltage_pu/1','Islanding_FSM/5');
AL('Grid_Freq_Hz/1',   'Islanding_FSM/6');

% VF model → FSM (feedback: island V and f)
AL('Island_VF_Model/1','Islanding_FSM/1'); % V_pu
AL('Island_VF_Model/2','Islanding_FSM/2'); % f_Hz
AL('Island_VF_Model/3','Islanding_FSM/3'); % ROCOF

% Battery command → Battery model
AL('MG_Controller/1','Battery_Model/1');


%% =========================================================
%% SECTION 10 — MONITORING SCOPES
%% =========================================================
% Scope 1: Power flows
AB('simulink/Sinks/Scope','Power_Scope','Position',[900,50,960,130]);
set_param([modelName '/Power_Scope'],'NumInputPorts','3');
AL('Load_Model/1',       'Power_Scope/1');  % Load
AL('Solar_PV_Profile/1', 'Power_Scope/2'); % Solar
AL('MG_Controller/1',    'Power_Scope/3'); % Battery

% Scope 2: Battery SOC
AB('simulink/Sinks/Scope','SOC_Scope','Position',[900,160,960,220]);
AL('Battery_Model/1','SOC_Scope/1');

% Scope 3: Voltage and frequency
AB('simulink/Sinks/Scope','VF_Scope','Position',[900,250,960,330]);
set_param([modelName '/VF_Scope'],'NumInputPorts','2');
AL('Island_VF_Model/1','VF_Scope/1');  % V_pu
AL('Island_VF_Model/2','VF_Scope/2');  % f_Hz

% Scope 4: FSM state and PCC status
AB('simulink/Sinks/Scope','State_Scope','Position',[900,350,960,430]);
set_param([modelName '/State_Scope'],'NumInputPorts','2');
AL('Islanding_FSM/3','State_Scope/1');  % state_id
AL('Islanding_FSM/1','State_Scope/2'); % pcc_closed

% To Workspace blocks — export data for Python/pandapower cross-check
AB('simulink/Sinks/To Workspace','WS_Power','Position',[900,450,960,490]);
set_param([modelName '/WS_Power'],'VariableName','sim_power','SaveFormat','timeseries');
AL('Load_Model/1','WS_Power/1');

AB('simulink/Sinks/To Workspace','WS_SOC','Position',[900,510,960,550]);
set_param([modelName '/WS_SOC'],'VariableName','sim_soc','SaveFormat','timeseries');
AL('Battery_Model/1','WS_SOC/1');


%% =========================================================
%% SAVE MODEL
%% =========================================================
save_system(modelName, savePath);

disp(' ');
disp('╔══════════════════════════════════════════════════════════╗');
disp('║  FIREBREAK MICROGRID v3 — Build Complete                 ║');
disp('╚══════════════════════════════════════════════════════════╝');
disp(['  Saved: ' savePath]);
disp(' ');
disp('WHAT WAS BUILT:');
disp('  ✓ Grid model       — 415V, 50Hz, fails at 17:00');
disp('  ✓ Solar PV         — 30 kWp, real daily profile');
disp('  ✓ Battery model    — 80 kWh, SOC integrator, starts 100%');
disp('  ✓ Loads (Tier 1)   — Telecom 47.6kW | Health 10kW | Fire 8.5kW | Water 16kW');
disp('  ✓ Islanding FSM    — MATLAB Function: GRID→ISLAND→RESYNC→RECONNECTED');
disp('  ✓ MG Controller    — Battery dispatched to fill solar gap');
disp('  ✓ VF Droop model   — Voltage & frequency during island');
disp('  ✓ Fire alarm input — Boolean, opens PCC immediately');
disp('  ✓ 4 Scopes         — Power flows | SOC | V&f | FSM state');
disp('  ✓ To Workspace     — sim_power, sim_soc for Python cross-check');
disp(' ');
disp('KEY SIMULATION EVENTS (set in model):');
disp('  t = 61200s (17:00) — Grid fails → PCC opens → Island mode');
disp('  t = 68400s (19:00) — Solar → 0, battery alone overnight');
disp('  t = 21600s (06:00) — Solar returns, battery recharging');
disp('  End SOC target: 32% (battery should NOT hit 20% min)');
disp(' ');
disp('STANDARDS COMPLIANCE:');
disp('  AS/NZS 4777.2 — UV=0.85pu, OV=1.10pu, UF=49Hz, OF=51Hz, ROCOF=1Hz/s');
disp('  Resync conditions: ΔV<5%, Δf<0.1Hz before PCC reclose');
disp(' ');
disp('NOTE: Open model in Simulink, check FSM block wiring,');
disp('      then press Run (Ctrl+T) to simulate.');
