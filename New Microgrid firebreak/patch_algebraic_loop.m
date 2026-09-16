%% patch_algebraic_loop.m
%% Fixes the algebraic loop in firebreak_microgrid
%% Inserts Unit Delay blocks on the VF_Model → FSM feedback paths
%% Run this in the MATLAB Command Window AFTER the model is open.

modelName = 'firebreak_microgrid';
savePath  = 'C:\Users\bawan\Documents\MATLAB\firebreak_microgrid.slx';

% Open if not already loaded
if ~bdIsLoaded(modelName)
    open_system(savePath);
end

disp('Patching algebraic loop...');

%% -------------------------------------------------------
%% STEP 1: Break Island_VF_Model/f_Hz  → Islanding_FSM/2
%% -------------------------------------------------------
try
    delete_line(modelName,'Island_VF_Model/2','Islanding_FSM/2');
    disp('  Removed: VF_Model f_Hz → FSM');
catch
    disp('  (f_Hz line already removed or not found — skipping)');
end

% Unit Delay for f_Hz  (initial = 50 Hz so FSM starts happy)
add_block('simulink/Discrete/Unit Delay', ...
    [modelName '/Delay_fHz'], ...
    'Position',[720,195,790,225]);
set_param([modelName '/Delay_fHz'], ...
    'InitialCondition','50', ...
    'SampleTime','0.1');

add_line(modelName,'Island_VF_Model/2','Delay_fHz/1','autorouting','on');
add_line(modelName,'Delay_fHz/1','Islanding_FSM/2','autorouting','on');
disp('  Added: VF_Model f_Hz → [Unit Delay 50Hz] → FSM');

%% -------------------------------------------------------
%% STEP 2: Break Island_VF_Model/ROCOF → Islanding_FSM/3
%% -------------------------------------------------------
try
    delete_line(modelName,'Island_VF_Model/3','Islanding_FSM/3');
    disp('  Removed: VF_Model ROCOF → FSM');
catch
    disp('  (ROCOF line already removed or not found — skipping)');
end

% Unit Delay for ROCOF (initial = 0 Hz/s — no rate of change at start)
add_block('simulink/Discrete/Unit Delay', ...
    [modelName '/Delay_ROCOF'], ...
    'Position',[720,245,790,275]);
set_param([modelName '/Delay_ROCOF'], ...
    'InitialCondition','0', ...
    'SampleTime','0.1');

add_line(modelName,'Island_VF_Model/3','Delay_ROCOF/1','autorouting','on');
add_line(modelName,'Delay_ROCOF/1','Islanding_FSM/3','autorouting','on');
disp('  Added: VF_Model ROCOF → [Unit Delay 0] → FSM');

%% -------------------------------------------------------
%% STEP 3: Break FSM island_active → Island_VF_Model/4
%%         (pcc_closed feedback also in the loop)
%% -------------------------------------------------------
try
    delete_line(modelName,'Islanding_FSM/1','Island_VF_Model/4');
    disp('  Removed: FSM pcc_closed → VF_Model');
catch
    disp('  (pcc_closed line not found — skipping)');
end

% Unit Delay for pcc_closed (initial = 1 → PCC starts closed)
add_block('simulink/Discrete/Unit Delay', ...
    [modelName '/Delay_pcc'], ...
    'Position',[720,295,790,325]);
set_param([modelName '/Delay_pcc'], ...
    'InitialCondition','1', ...
    'SampleTime','0.1');

add_line(modelName,'Islanding_FSM/1','Delay_pcc/1','autorouting','on');
add_line(modelName,'Delay_pcc/1','Island_VF_Model/4','autorouting','on');
disp('  Added: FSM pcc_closed → [Unit Delay 1] → VF_Model');

%% -------------------------------------------------------
%% SAVE
%% -------------------------------------------------------
save_system(modelName, savePath);

disp(' ');
disp('╔══════════════════════════════════════════════════════════╗');
disp('║  Algebraic loop patched — Unit Delays inserted           ║');
disp('╚══════════════════════════════════════════════════════════╝');
disp('  Delay_fHz   : f_Hz feedback  (IC = 50 Hz)');
disp('  Delay_ROCOF : ROCOF feedback (IC = 0 Hz/s)');
disp('  Delay_pcc   : pcc_closed feedback (IC = 1 = closed)');
disp(' ');
disp('Now press Ctrl+T in Simulink to run the 24-hour simulation.');
