// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// 直接引入 OpenZeppelin 的 ERC721 标准库与权限控制模块
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title SkillNetMedal
 * @dev epochChain 团队专用的 SkillNet 学习勋章 NFT 合约
 * 专为 ETH Beijing 2026 极客任务与课程商城兑换设计
 */
contract SkillNetMedal is ERC721URIStorage, Ownable {
    uint256 private _nextTokenId;

    // 记录 NFT 铸造事件
    event MedalMinted(address indexed to, uint256 indexed tokenId, string uri);

    // 初始化 NFT 的名称和简称
    constructor() ERC721("SkillNet Academic Medal", "SNM") Ownable(msg.sender) {}

    /**
     * @notice 为商城库存铸造新的 NFT 勋章
     * @param to 接收地址（通常是项目方国库或 Owner 地址，用于 SkillNet 合约后续划转）
     * @param uri NFT 的元数据地址（例如孙同学在管理端配置的 IPFS CID 链接）
     * @return 返回新铸造的 Token ID
     */
    function mintMedal(address to, string memory uri) public onlyOwner returns (uint256) {
        uint256 tokenId = _nextTokenId++;
        
        _safeMint(to, tokenId);
        _setTokenURI(tokenId, uri);
        
        emit MedalMinted(to, tokenId, uri);
        return tokenId;
    }

    /**
     * @notice 批量铸造同款勋章（方便一次性填充商城的初始库存）
     * @param to 接收地址
     * @param baseUri 该批次勋章共享的元数据链接
     * @param amount 铸造数量
     */
    function batchMint(address to, string memory baseUri, uint256 amount) public onlyOwner {
        for (uint256 i = 0; i < amount; i++) {
            uint256 tokenId = _nextTokenId++;
            
            _safeMint(to, tokenId);
            _setTokenURI(tokenId, baseUri);
            
            emit MedalMinted(to, tokenId, baseUri);
        }
    }

    /**
     * @notice 获取当前已铸造的 NFT 总量（也可用于查询下一个可用的 Token ID）
     */
    function totalSupply() public view returns (uint256) {
        return _nextTokenId;
    }
}