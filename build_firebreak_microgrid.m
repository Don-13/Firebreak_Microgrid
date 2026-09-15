%% =========================================================
%% Firebreak Energy Systems — Community Microgrid
%% Simulink Model Builder Script
%% Team 10 | Don Weerakoon (14517243) | Professional Studio B
%% =========================================================

modelName = 'firebreak_microgrid';
savePath  = 'C:\Users\bawan\Documents\MATLAB\firebreak_microgrid.slx';

%% --- Close existing model if open ---
if bdIsLoaded(modelName)
    close_system(modelName, 0);
end

%% --- Create new model ---
new_system(modelName);
open_system(modelName);

% Simulation settings (20 seconds, stiff ODE solver for power systems)
set_param(modelName, ...
    'StopTime',  '20', ...
    'Solver',    'ode23tb', ...
    'MaxStep',   '1e-4', ...
    'RelTol',    '1e-3');

%% --- powergui block (REQUIRED for SimPowerSystems) ---
add_block('powerlib/powergui', [modelName '/powergui'], ...
    'Position', [20, 20, 90, 60], ...
    'SimulationMode', 'Continuous');


%% =========================================================
%% 1. GRID SOURCE  (415 V line-to-line, 50 Hz, 3-phase)
%% =========================================================
add_block('powerlib/Electrical Sources/Three-Phase Source', ...
    [modelName '/Grid_Source'], ...
    'Position', [80, 220, 160, 280]);
set_param([modelName '/Grid_Source'], ...
    'Voltage',   '415', ...
    'Frequency', '50', ...
    'Impedance', 'off');   % Ideal source; set 'on' for Thevenin impedance


%% =========================================================
%% 2. PCC BREAKER (Point of Common Coupling)
%%    External control signal: 1 = closed, 0 = open
%% =========================================================
add_block('powerlib/Elements/Three-Phase Breaker', ...
    [modelName '/PCC_Breaker'], ...
    'Position', [230, 220, 310, 280]);
set_param([modelName '/PCC_Breaker'], ...
    'InitialState', '1', ...   % Start closed (grid-connected)
    'SwitchTimes',  '[]', ...
    'ExternalSwitchingTime', 'on');


%% =========================================================
%% 3. PCC VOLTAGE & CURRENT MEASUREMENT
%%    Feeds islanding detection algorithm
%% =========================================================
add_block('powerlib/Measurements/Three-Phase V-I Measurement', ...
    [modelName '/PCC_Measurement'], ...
    'Position', [370, 220, 460, 280]);
set_param([modelName '/PCC_Measurement'], ...
    'VoltagesMeasurement', 'phase-to-ground', ...
    'CurrentsMeasurement', 'yes');


%% =========================================================
%% 4. SOLAR PV  (30 kWp)
%%    Modelled as an ideal 3-phase source in anti-parallel
%%    (replace with Simscape PV Array + inverter for detail)
%% =========================================================
add_block('powerlib/Electrical Sources/Three-Phase Source', ...
    [modelName '/Solar_PV_30kWp'], ...
    'Position', [370, 80, 460, 140]);
set_param([modelName '/Solar_PV_30kWp'], ...
    'Voltage',   '415', ...
    'Frequency', '50', ...
    'Impedance', 'on', ...
    'R1', '0.5', ...    % Internal resistance (Ohms)
    'L1', '0.002');     % Leakage inductance (H)
% NOTE: For accurate PV simulation, replace this block with:
%   Simscape Electrical > Sources > Solar Cell (or PV Array)
%   followed by a DC/AC inverter and LCL filter.


%% =========================================================
%% 5. BATTERY STORAGE  (80 kWh, ~100 kW peak inverter)
%%    Modelled as a controllable voltage source
%%    (replace with Simscape Battery block for SOC tracking)
%% =========================================================
add_block('powerlib/Electrical Sources/Three-Phase Source', ...
    [modelName '/Battery_Inverter_80kWh'], ...
    'Position', [370, 340, 460, 400]);
set_param([modelName '/Battery_Inverter_80kWh'], ...
    'Voltage',   '415', ...
    'Frequency', '50', ...
    'Impedance', 'on', ...
    'R1', '0.2', ...
    'L1', '0.001');
% NOTE: Replace with:
%   Simscape Electrical > Batteries > Battery (table-based)
%   + bidirectional DC/DC converter + DC/AC inverter


%% =========================================================
%% 6. CRITICAL LOADS  (4 buildings)
%%    Three-Phase Parallel RLC Load — resistive-inductive
%% =========================================================
loadNames  = {'Evacuation_Centre', 'Fire_Station', 'Hospital', 'Community_Hall'};
loadPower  = [15000, 10000, 20000, 8000];   % Active power (W)
loadPF     = [0.90,  0.85,  0.92,  0.88];  % Power factor (lagging)

for k = 1:4
    yPos      = 100 + (k-1)*130;
    blk       = [modelName '/' loadNames{k}];
    add_block('powerlib/Elements/Three-Phase Parallel RLC Load', ...
        blk, 'Position', [600, yPos, 710, yPos+60]);

    V  = 415;                          % Line voltage (V)
    P  = loadPower(k);
    pf = loadPF(k);
    R  = (V^2 * pf) / P;              % Equivalent resistance
    Q  = P * tan(acos(pf));           % Reactive power
    L  = (V^2) / (2*pi*50*Q);        % Equivalent inductance

    set_param(blk, ...
        'Resistance',  num2str(R,  '%.4f'), ...
        'Inductance',  num2str(L,  '%.6f'), ...
        'Capacitance', 'inf');         % No capacitance (lagging load)
end


%% =========================================================
%% 7. ELECTRICAL CONNECTIONS
%%    Grid_Source → PCC_Breaker → PCC_Measurement → Bus
%%    Solar_PV and Battery also connect to the same Bus node
%% =========================================================
add_line(modelName, 'Grid_Source/1',    'PCC_Breaker/1',    'autorouting','on');
add_line(modelName, 'PCC_Breaker/2',    'PCC_Measurement/1','autorouting','on');

% NOTE: Connect PCC_Measurement port 2 (output bus) to:
%   Solar_PV_30kWp, Battery_Inverter_80kWh, and all 4 loads
%   Do this graphically in Simulink after running this script.
%   Use a Bus Creator or wire junction to split the bus.


%% =========================================================
%% 8. ISLANDING DETECTION SUBSYSTEM
%%    Inputs : Va, Vb, Vc (from PCC_Measurement)
%%    Output : island_trip (1 = islanding detected)
%%    Method : Undervoltage + ROCOF (df/dt > 1 Hz/s)
%% =========================================================
add_block('simulink/Ports & Subsystems/Subsystem', ...
    [modelName '/Islanding_Detection'], ...
    'Position', [500, 480, 660, 560]);

iSys = [modelName '/Islanding_Detection'];
Simulink.SubSystem.deleteContents(iSys);

% --- Input ports ---
add_block('simulink/Sources/In1', [iSys '/Va'],  'Position',[30, 40, 60, 60]);
add_block('simulink/Sources/In1', [iSys '/Vb'],  'Position',[30, 90, 60, 110]);
add_block('simulink/Sources/In1', [iSys '/Vc'],  'Position',[30,140, 60, 160]);

% --- RMS of Va for magnitude check ---
add_block('simulink/Math Operations/Math Function', ...
    [iSys '/Va_squared'], 'Position',[90, 40,140, 70]);
set_param([iSys '/Va_squared'], 'Operator', 'square');

add_block('simulink/Sinks/Terminator', [iSys '/VbTerm'], 'Position',[90,90,110,110]);
add_block('simulink/Sinks/Terminator', [iSys '/VcTerm'], 'Position',[90,140,110,160]);
add_line(iSys, 'Vb/1','VbTerm/1');
add_line(iSys, 'Vc/1','VcTerm/1');

% --- Moving Average (approximate RMS) ---
add_block('simulink/Continuous/Transfer Fcn', [iSys '/LP_Filter'], ...
    'Position',[160, 35, 240, 75]);
set_param([iSys '/LP_Filter'], ...
    'Numerator',   '[314.16]', ...    % ω₀ = 2π×50
    'Denominator', '[1 314.16]');     % First-order LP at 50 Hz

add_block('simulink/Math Operations/Math Function', ...
    [iSys '/Va_rms'], 'Position',[260, 35, 310, 75]);
set_param([iSys '/Va_rms'], 'Operator', 'sqrt');

add_line(iSys, 'Va/1',       'Va_squared/1');
add_line(iSys, 'Va_squared/1','LP_Filter/1');
add_line(iSys, 'LP_Filter/1','Va_rms/1');

% --- Undervoltage check: Vrms < 353 V (0.85 pu) ---
add_block('simulink/Logic and Bit Operations/Compare To Constant', ...
    [iSys '/UV_Check'], 'Position',[340, 35, 450, 75]);
set_param([iSys '/UV_Check'], 'const','353', 'relop','<');
add_line(iSys, 'Va_rms/1', 'UV_Check/1');

% --- Frequency from zero-crossing (simplified: derivative of angle) ---
% Use a discrete derivative of Va to estimate df/dt
add_block('simulink/Continuous/Derivative', [iSys '/dVa_dt'], ...
    'Position',[90, 190, 150, 230]);
add_block('simulink/Continuous/Derivative', [iSys '/d2Va_dt2'], ...
    'Position',[170, 190, 230, 230]);

add_block('simulink/Math Operations/Divide', [iSys '/Freq_Est'], ...
    'Position',[260, 185, 310, 235]);

add_block('simulink/Math Operations/Gain', [iSys '/Freq_Scale'], ...
    'Position',[330, 190, 390, 230]);
set_param([iSys '/Freq_Scale'], 'Gain', '1/(2*pi)');

add_block('simulink/Continuous/Derivative', [iSys '/ROCOF'], ...
    'Position',[420, 190, 480, 230]);

add_block('simulink/Math Operations/Abs', [iSys '/ROCOF_Abs'], ...
    'Position',[510, 190, 560, 230]);

add_block('simulink/Logic and Bit Operations/Compare To Constant', ...
    [iSys '/ROCOF_Check'], 'Position',[590, 185, 700, 235]);
set_param([iSys '/ROCOF_Check'], 'const','1.0', 'relop','>');  % > 1 Hz/s threshold

add_line(iSys, 'Va/1',        'dVa_dt/1');
add_line(iSys, 'dVa_dt/1',    'd2Va_dt2/1');
add_line(iSys, 'd2Va_dt2/1',  'Freq_Est/1');
add_line(iSys, 'dVa_dt/1',    'Freq_Est/2');
add_line(iSys, 'Freq_Est/1',  'Freq_Scale/1');
add_line(iSys, 'Freq_Scale/1','ROCOF/1');
add_line(iSys, 'ROCOF/1',     'ROCOF_Abs/1');
add_line(iSys, 'ROCOF_Abs/1', 'ROCOF_Check/1');

% --- OR: trip if UV OR high ROCOF ---
add_block('simulink/Logic and Bit Operations/Logical Operator', ...
    [iSys '/Trip_OR'], 'Position',[740, 80, 800, 200]);
set_param([iSys '/Trip_OR'], 'Operator','OR', 'Inputs','2');
add_line(iSys, 'UV_Check/1',    'Trip_OR/1');
add_line(iSys, 'ROCOF_Check/1', 'Trip_OR/2');

% --- Output port ---
add_block('simulink/Sinks/Out1', [iSys '/island_trip'], ...
    'Position',[840, 120, 870, 150]);
add_line(iSys, 'Trip_OR/1', 'island_trip/1');


%% =========================================================
%% 9. RESYNCHRONISATION SUBSYSTEM
%%    Checks: |V_grid - V_island| < 5%
%%            |f_grid - f_island| < 0.1 Hz
%%            |θ_grid - θ_island| < 10°
%%    Output: reclose_ok (1 = safe to reclose PCC)
%%    (Simplified — expand with PLL blocks for accuracy)
%% =========================================================
add_block('simulink/Ports & Subsystems/Subsystem', ...
    [modelName '/Resync_Logic'], ...
    'Position', [500, 590, 660, 660]);

rSys = [modelName '/Resync_Logic'];
Simulink.SubSystem.deleteContents(rSys);

add_block('simulink/Sources/In1',  [rSys '/V_error'],  'Position',[30, 40,  60,  60]);
add_block('simulink/Sources/In1',  [rSys '/f_error'],  'Position',[30, 90,  60,  110]);
add_block('simulink/Sources/In1',  [rSys '/ph_error'], 'Position',[30, 140, 60,  160]);

add_block('simulink/Logic and Bit Operations/Compare To Constant', ...
    [rSys '/V_ok'],  'Position',[100,35,210,65]);
set_param([rSys '/V_ok'],  'const','0.05', 'relop','<');  % < 5% voltage error

add_block('simulink/Logic and Bit Operations/Compare To Constant', ...
    [rSys '/f_ok'],  'Position',[100,85,210,115]);
set_param([rSys '/f_ok'],  'const','0.1',  'relop','<');  % < 0.1 Hz freq error

add_block('simulink/Logic and Bit Operations/Compare To Constant', ...
    [rSys '/ph_ok'], 'Position',[100,135,210,165]);
set_param([rSys '/ph_ok'], 'const','10',   'relop','<');  % < 10° phase error

add_line(rSys, 'V_error/1',  'V_ok/1');
add_line(rSys, 'f_error/1',  'f_ok/1');
add_line(rSys, 'ph_error/1', 'ph_ok/1');

add_block('simulink/Logic and Bit Operations/Logical Operator', ...
    [rSys '/AND_Gate'], 'Position',[260, 70, 320, 160]);
set_param([rSys '/AND_Gate'], 'Operator','AND', 'Inputs','3');
add_line(rSys, 'V_ok/1',  'AND_Gate/1');
add_line(rSys, 'f_ok/1',  'AND_Gate/2');
add_line(rSys, 'ph_ok/1', 'AND_Gate/3');

add_block('simulink/Sinks/Out1', [rSys '/reclose_ok'], ...
    'Position',[370, 100, 400, 130]);
add_line(rSys, 'AND_Gate/1', 'reclose_ok/1');


%% =========================================================
%% 10. FIRE DETECTION INPUT
%%     Set Value to '1' to simulate fire trigger (opens PCC)
%% =========================================================
add_block('simulink/Sources/Constant', ...
    [modelName '/Fire_Detected'], ...
    'Position', [50, 500, 160, 540]);
set_param([modelName '/Fire_Detected'], 'Value', '0');
% Set to '1' or use a Step block to simulate fire event at t=5s


%% =========================================================
%% 11. PCC TRIP LOGIC
%%     OPEN breaker if: islanding detected OR fire detected
%%     RECLOSE breaker if: reclose_ok AND NOT island AND NOT fire
%% =========================================================
add_block('simulink/Logic and Bit Operations/Logical Operator', ...
    [modelName '/Open_OR'], ...
    'Position', [720, 490, 800, 560]);
set_param([modelName '/Open_OR'], 'Operator','OR', 'Inputs','2');

% NOT gate: breaker signal = 1(closed), trip=1 means OPEN → invert
add_block('simulink/Logic and Bit Operations/Logical Operator', ...
    [modelName '/Trip_NOT'], ...
    'Position', [830, 500, 910, 550]);
set_param([modelName '/Trip_NOT'], 'Operator','NOT');

add_line(modelName, 'Fire_Detected/1',       'Open_OR/1', 'autorouting','on');
add_line(modelName, 'Islanding_Detection/1', 'Open_OR/2', 'autorouting','on');
add_line(modelName, 'Open_OR/1',             'Trip_NOT/1','autorouting','on');
% Trip_NOT output (breaker control) → PCC_Breaker port 2
add_line(modelName, 'Trip_NOT/1',            'PCC_Breaker/2','autorouting','on');

%% Connect PCC_Measurement voltages → Islanding_Detection
add_line(modelName, 'PCC_Measurement/1', 'Islanding_Detection/1', 'autorouting','on');
add_line(modelName, 'PCC_Measurement/2', 'Islanding_Detection/2', 'autorouting','on');
add_line(modelName, 'PCC_Measurement/3', 'Islanding_Detection/3', 'autorouting','on');


%% =========================================================
%% 12. SCOPES FOR MONITORING
%% =========================================================
% Voltage scope at PCC
add_block('simulink/Sinks/Scope', [modelName '/Voltage_Scope'], ...
    'Position', [800, 200, 860, 260]);
set_param([modelName '/Voltage_Scope'], 'NumInputPorts','3');
add_line(modelName, 'PCC_Measurement/1', 'Voltage_Scope/1','autorouting','on');
add_line(modelName, 'PCC_Measurement/2', 'Voltage_Scope/2','autorouting','on');
add_line(modelName, 'PCC_Measurement/3', 'Voltage_Scope/3','autorouting','on');

% Breaker status scope
add_block('simulink/Sinks/Scope', [modelName '/Breaker_Status_Scope'], ...
    'Position', [940, 490, 1000, 550]);
add_line(modelName, 'Trip_NOT/1', 'Breaker_Status_Scope/1','autorouting','on');


%% =========================================================
%% SAVE MODEL
%% =========================================================
save_system(modelName, savePath);

disp(' ');
disp('=================================================');
disp(' Firebreak Microgrid Model — Build Complete!');
disp('=================================================');
disp(['  Saved to: ' savePath]);
disp(' ');
disp('NEXT STEPS IN SIMULINK:');
disp('  1. Connect Solar_PV and Battery to the PCC bus (wire to PCC_Measurement port 2)');
disp('  2. Connect all 4 load blocks to the same bus');
disp('  3. Connect Resync_Logic inputs (V/f/phase error signals)');
disp('  4. Set Fire_Detected Value to 1 to test fire trip');
disp('  5. Press Run (Ctrl+T) — simulation runs for 20 seconds');
disp('  6. Open Voltage_Scope and Breaker_Status_Scope to view results');
disp(' ');
