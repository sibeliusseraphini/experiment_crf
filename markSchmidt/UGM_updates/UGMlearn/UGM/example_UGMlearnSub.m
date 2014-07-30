
if subDisplay ~= -1
fprintf('\n\nTraining %s...\n',type);
end

% Make EdgeStruct
edgeStruct = UGM_makeEdgeStruct(adjInit);
nEdges = size(edgeStruct.edgeEnds,1);
Xedge = UGM_makeEdgeFeatures(X,edgeStruct.edgeEnds);

% Add Node Bias
Xnode = [ones(nInstances,1,nNodes) X];
Xedge = [ones(nInstances,1,nEdges) Xedge];

% Make infoStruct and initialize weights
infoStruct = UGM_makeInfoStruct(Xnode,Xedge,edgeStruct,nStates,ising,tied,useMex);
[nodeWeights,edgeWeights] = UGM_initWeights(infoStruct,'zeros');
nVars = numel(nodeWeights)+numel(edgeWeights);

% Set up Objective
if strcmp(trainType,'pseudo')
    funObj_sub = @(weights)UGM_PseudoLoss(weights,Xnode(trainNdx,:,:),Xedge(trainNdx,:,:),y(trainNdx,:),edgeStruct,infoStruct);
elseif strcmp(trainType,'loopy')
    funObj_sub = @(weights)UGM_Loss(weights,Xnode(trainNdx,:,:),Xedge(trainNdx,:,:),y(trainNdx,:),edgeStruct,infoStruct,@UGM_Infer_LBP);
elseif strcmp(trainType,'exact')
    funObj_sub = @(weights)UGM_Loss(weights,Xnode(trainNdx,:,:),Xedge(trainNdx,:,:),y(trainNdx,:),edgeStruct,infoStruct,@UGM_Infer_Exact);
else
    fprintf('Unrecognized trainType: %s\n',trainType);
    pause;
end

% Set up Regularizer and Train
nodePenalty = lambdaNode*ones(size(nodeWeights));
nodePenalty(1,:,:) = 0; % Don't penalize node bias
edgePenalty = lambdaEdge*ones(size(edgeWeights));
    options = [];
if strcmp(edgePenaltyType,'L2')
    % Train with L2-regularization on node and edge parameters
    if display == 0
        options.Display = 'none';
    end
    funObj = @(weights)penalizedL2(weights,funObj_sub,[nodePenalty(:);edgePenalty(:)]);
    weights = minFunc(funObj,zeros(nVars,1),options);
elseif strcmp(edgePenaltyType,'L1')
    % Train with L2-regularization on node parameters and
    % L1-regularization on edge parameters
    if display == 0
        options.verbose = 0;
    end
    funObjL2 = @(weights)penalizedL2(weights,funObj_sub,[nodePenalty(:);zeros(size(edgeWeights(:)))]); % L2 on Node Parameters
    funObj = @(weights)nonNegGrad(weights,[zeros(size(nodeWeights(:)));edgePenalty(:)],funObjL2);
    weights = minConF_BC(funObj,zeros(2*nVars,1),zeros(2*nVars,1),inf(2*nVars,1),options);
    weights = weights(1:nVars)-weights(nVars+1:end);
else
    % Train with L2-regularization on node parameters and
    % group L1-regularization on edge parameters
    if display == 0
        options.verbose = 0;
    end
    groups = zeros(size(edgeWeights));
    for e = 1:nEdges
        groups(:,:,e) = e;
    end
    nGroups = length(unique(groups(groups>0)));

    funObjL2 = @(weights)penalizedL2(weights,funObj_sub,[nodePenalty(:);zeros(size(edgeWeights(:)))]); % L2 on Node Parameters
    nodeGroups = zeros(size(nodeWeights));
    edgeGroups = groups;
    groups = [nodeGroups(:);edgeGroups(:)];


    funObj = @(weights)auxGroupLoss(weights,groups,lambdaEdge,funObjL2);
    if strcmp(edgePenaltyType,'L1-L2')
        funProj = @(weights)auxGroupL2Proj(weights,groups);
    elseif strcmp(edgePenaltyType,'L1-Linf')
        funProj = @(weights)auxGroupLinfProj(weights,groups);
    else
        fprintf('Unrecognized edgePenaltyType\n');
        pause;
    end

    weights = minConF_SPG(funObj,[zeros(nVars,1);zeros(nGroups,1)],funProj,options);
    weights = weights(1:nVars);
end
[nodeWeights,edgeWeights] = UGM_splitWeights(weights,infoStruct);

% Compute Node/Edge Potentials
nodePot = UGM_makeNodePotentials(Xnode,nodeWeights,infoStruct);
edgePot = UGM_makeEdgePotentials(Xedge,edgeWeights,edgeStruct,infoStruct);

% Compute Error on Test Data
err = 0;
for i = testNdx
    if strcmp(testType,'exact')
        [nodeBel,edge,logZ] = UGM_Infer_Exact(nodePot(:,:,i),edgePot(:,:,:,i),edgeStruct,infoStruct);
    elseif strcmp(testType,'loopy')
        [nodeBel,edge,logZ] = UGM_Infer_LBP(nodePot(:,:,i),edgePot(:,:,:,i),edgeStruct,infoStruct);
    else
        fprintf('Unrecognized testType: %s\n',testType);
        pause;
    end
    [margConf yMaxMarg] = max(nodeBel,[],2);
    err = err + sum(yMaxMarg' ~= y(i,:));
end
err = err/(length(testNdx)*nNodes);

if subDisplay ~= -1
fprintf('Error Rate (%s): %.3f\n',type,err);
end

% Find active edges
adjFinal = zeros(nNodes);
for e = 1:nEdges
    if any(abs(edgeWeights(:,:,e)) > 1e-4)
        n1 = edgeStruct.edgeEnds(e,1);
        n2 = edgeStruct.edgeEnds(e,2);
        adjFinal(n1,n2) = 1;
        adjFinal(n2,n1) = 1;
    end
end
if subDisplay > 0
    f = f+1;figure(f);clf;hold on;
    drawGraph(adjFinal);
    title(sprintf('%s (err = %.3f)',type,err));
    pause;
end